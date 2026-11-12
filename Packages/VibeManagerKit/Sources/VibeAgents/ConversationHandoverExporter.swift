import Darwin
import Foundation
import VibeApplication
import VibeDomain

/// Copies native logs without interpreting or losing tool results. Nothing in the source homes
/// is changed. Each export owns its directory, so a later switch cannot invalidate an old one.
///
/// The logs are found where every other reader finds them, `TranscriptLocationCache`, and copied
/// once the agent writing them has stopped: a clone on APFS, which takes neither time nor space.
public actor ConversationHandoverExporter: ConversationHandoverExporting {
  private let directory: URL
  private let locations: TranscriptLocationCache

  public init(directory: URL, locations: TranscriptLocationCache) {
    self.directory = directory
    self.locations = locations
  }

  public init(directory: URL, locator: AgentTranscriptLocator = AgentTranscriptLocator()) {
    self.init(directory: directory, locations: TranscriptLocationCache(locator: locator))
  }

  private struct Source {
    let label: String
    let file: URL
    let isCodex: Bool
    let providerID: String
  }

  private struct Found {
    var sources: [Source] = []
    /// Earlier conversations without a log, or without an identifier to find one by.
    var missing: [String] = []
    var includesLatest = false
  }

  public func availability(of session: WorkSession) -> ConversationHistoryAvailability {
    let found = find(in: session)
    return ConversationHistoryAvailability(
      includesLatest: found.includesLatest, isPartial: !found.missing.isEmpty)
  }

  public func reserve(for session: WorkSession) -> ConversationHandover {
    let folder = directory.appendingPathComponent(session.id.rawValue.uuidString)
      .appendingPathComponent(UUID().uuidString)
    return ConversationHandover(index: folder.appendingPathComponent("history.md"), byteCount: 0)
  }

  public func export(_ session: WorkSession, into reserved: ConversationHandover) throws
    -> ConversationHandover
  {
    let found = find(in: session)
    guard found.includesLatest else { throw ConversationHandoverError.unavailable }
    let manager = FileManager.default
    let destination = reserved.directory
    guard isOwned(destination) else { throw ConversationHandoverError.cannotCopy }
    do {
      try manager.createDirectory(
        at: destination, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var index = "# Conversation history\n\nSession: \(session.name)\n\n"
      index += "Snapshot of the available native logs in conversation order. Each file is JSONL. "
      index += "Sub-agent files are labelled by their original filename.\n\n"
      if !found.missing.isEmpty {
        index +=
          "Unavailable conversations (history is partial): "
          + "\(found.missing.joined(separator: ", "))\n\n"
      }
      var bytes = 0
      var copied = 0
      var seen = Set(found.sources.map(\.file.standardizedFileURL.path))
      // Sub-agents already looked for: a rollout naming one again costs no other walk.
      var lookedFor: Set<String> = []
      var round = found.sources
      // Breadth first: the conversations, then their sub-agents, then theirs. Each round of Codex
      // sub-agents is looked for in one walk through the day folders.
      while !round.isEmpty {
        var threads: [String: Set<String>] = [:]
        for source in round {
          copied += 1
          let copy = destination.appendingPathComponent("\(copied).jsonl")
          bytes += try snapshot(source.file, to: copy)
          index +=
            "- \(source.label); original filename: "
            + "\(ConversationHandover.quoted(source.file.lastPathComponent)); "
            + "copied file: \(ConversationHandover.quoted(copy.path))\n"
          if source.isCodex {
            let named = codexSubagents(in: copy).subtracting(lookedFor)
            lookedFor.formUnion(named)
            if !named.isEmpty { threads[source.providerID, default: []].formUnion(named) }
          }
        }
        round = []
        for (providerID, identifiers) in threads.sorted(by: { $0.key < $1.key }) {
          let files = locations.locator.codexRollouts(
            for: identifiers, providerID: providerID, since: session.createdAt
          ).sorted { $0.lastPathComponent < $1.lastPathComponent }
          for identifier in identifiers.sorted() {
            let own = files.filter { $0.lastPathComponent.contains(identifier) }
            if own.isEmpty { index += "- Unavailable sub-agent: \(identifier)\n" }
            for file in own where seen.insert(file.standardizedFileURL.path).inserted {
              round.append(
                Source(
                  label: "codex / sub-agent / \(identifier)", file: file, isCodex: true,
                  providerID: providerID))
            }
          }
        }
      }
      guard bytes > 0 else { throw ConversationHandoverError.unavailable }
      guard
        manager.createFile(
          atPath: reserved.index.path, contents: Data(index.utf8),
          attributes: [.posixPermissions: 0o600])
      else { throw ConversationHandoverError.cannotCopy }
      return ConversationHandover(index: reserved.index, byteCount: bytes)
    } catch {
      try? manager.removeItem(at: destination)
      if let known = error as? ConversationHandoverError { throw known }
      throw ConversationHandoverError.cannotCopy
    }
  }

  public func discard(_ handover: ConversationHandover) {
    let folder = handover.directory
    guard isOwned(folder) else { return }
    let manager = FileManager.default
    try? manager.removeItem(at: folder)
    // The session's folder goes with its last copy.
    let session = folder.deletingLastPathComponent()
    if (try? manager.contentsOfDirectory(atPath: session.path))?.isEmpty == true {
      try? manager.removeItem(at: session)
    }
  }

  /// Only a folder of this exporter's own, two levels down, is written or removed.
  private func isOwned(_ folder: URL) -> Bool {
    folder.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().path
      == directory.standardizedFileURL.path
  }

  /// Every conversation of the session, in order, with the files its CLI left, and whether the one
  /// being left is among them.
  private func find(in session: WorkSession) -> Found {
    var found = Found()
    var seen: Set<String> = []
    // A conversation that never got an identifier left logs nobody can find. One that never ran,
    // before a first launch, left none.
    for change in session.agentHistory
    where change.handover != .initialPrompt
      && (change.previous.resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines))?
        .isEmpty != false
    {
      found.missing.append("\(change.previous.providerID) (no conversation identifier)")
    }
    for conversation in session.conversations {
      // The one the session runs now: its last, the request a new agent is told to resume.
      let isLatest =
        conversation.providerID == session.agent?.providerID
        && conversation.resumeIdentifier == session.agent?.resumeIdentifier
      guard let transcripts = locations.transcripts(of: conversation, in: session),
        !transcripts.files.isEmpty,
        !transcripts.identifier.contains("/"), !transcripts.identifier.contains("..")
      else {
        if !isLatest { found.missing.append(conversation.providerID) }
        continue
      }
      if isLatest { found.includesLatest = true }
      let label =
        "\(conversation.providerID) / \(conversation.transcriptProviderID) / "
        + transcripts.identifier
      for file in transcripts.files.sorted(by: { $0.path < $1.path })
      where seen.insert(file.standardizedFileURL.path).inserted {
        found.sources.append(
          Source(
            label: label, file: file, isCodex: transcripts.isCodex,
            providerID: conversation.providerID))
      }
    }
    return found
  }

  /// The Codex sub-agents a copied rollout names, read as the conversation reads them. Only the
  /// lines that can be such a record are parsed: a rollout runs to hundreds of megabytes.
  private func codexSubagents(in file: URL) -> Set<String> {
    let marker = Data("SubAgentActivity".utf8)
    var reader = TranscriptLineReader(file: file)
    var identifiers: Set<String> = []
    while true {
      let reading = autoreleasepool {
        let reading = reader.readChunk()
        for line in reading.lines where line.range(of: marker) != nil {
          guard let record = TranscriptRecord(line: line),
            let identifier = CodexConversationDecoder.subagentThread(inRecord: record.object),
            !identifier.isEmpty, !identifier.contains("/"), !identifier.contains("..")
          else { continue }
          identifiers.insert(identifier)
        }
        return reading
      }
      if !reading.hasMore { return identifiers }
    }
  }

  /// A clone where the volume makes them, else a copy bounded to the size at open. Never loads a
  /// conversation into memory, and never follows a symbolic link supplied as a transcript.
  private func snapshot(_ source: URL, to destination: URL) throws -> Int {
    let descriptor = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw ConversationHandoverError.cannotCopy }
    let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? input.close() }
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0,
      (attributes.st_mode & S_IFMT) == S_IFREG
    else { throw ConversationHandoverError.cannotCopy }
    if destination.path.withCString({ fclonefileat(descriptor, AT_FDCWD, $0, 0) }) == 0 {
      var cloned = stat()
      guard chmod(destination.path, 0o600) == 0, stat(destination.path, &cloned) == 0 else {
        throw ConversationHandoverError.cannotCopy
      }
      return Int(cloned.st_size)
    }
    let size = try input.seekToEnd()
    try input.seek(toOffset: 0)
    guard
      FileManager.default.createFile(
        atPath: destination.path, contents: nil,
        attributes: [.posixPermissions: 0o600])
    else { throw ConversationHandoverError.cannotCopy }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var remaining = size
    while remaining > 0 {
      let data = try input.read(upToCount: Int(min(remaining, 65_536))) ?? Data()
      guard !data.isEmpty else { throw ConversationHandoverError.cannotCopy }
      try output.write(contentsOf: data)
      remaining -= UInt64(data.count)
    }
    return Int(size)
  }
}
