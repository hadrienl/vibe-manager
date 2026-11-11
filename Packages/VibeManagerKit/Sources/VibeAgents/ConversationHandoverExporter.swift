import Darwin
import Foundation
import VibeApplication
import VibeDomain

/// Copies native logs without interpreting or losing tool results. Nothing in the source homes
/// is changed. Each export owns its directory, so a later switch cannot invalidate an old one.
public actor ConversationHandoverExporter: ConversationHandoverExporting {
  private let directory: URL
  private let locator: AgentTranscriptLocator

  public init(directory: URL, locator: AgentTranscriptLocator = AgentTranscriptLocator()) {
    self.directory = directory
    self.locator = locator
  }

  public func export(_ session: WorkSession) throws -> ConversationHandover {
    let manager = FileManager.default
    let destination = directory.appendingPathComponent(session.id.rawValue.uuidString)
      .appendingPathComponent(UUID().uuidString)
    var sources: [(label: String, file: URL, isCodex: Bool, providerID: String)] = []
    var seen: Set<String> = []
    var missing: [String] = []
    for conversation in session.conversations {
      let provider = conversation.transcriptProviderID
      guard let identifier = conversation.resumeIdentifier, !identifier.isEmpty,
        !identifier.contains("/"), !identifier.contains("..")
      else {
        missing.append(conversation.providerID)
        continue
      }
      let files: [URL]
      switch provider {
      case ClaudeCodeAgentProvider.id.rawValue:
        files = locator.claudeTranscripts(for: identifier, providerID: conversation.providerID)
          .sorted { $0.path < $1.path }
      case CodexAgentProvider.id.rawValue:
        files = locator.codexRollouts(
          for: identifier, providerID: conversation.providerID, since: session.createdAt
        ).sorted {
          $0.path < $1.path
        }
      default:
        files = []
      }
      if files.isEmpty { missing.append(conversation.providerID) }
      for file in files where seen.insert(file.standardizedFileURL.path).inserted {
        sources.append(
          (
            "\(conversation.providerID) / \(provider) / \(identifier)", file,
            provider == CodexAgentProvider.id.rawValue, conversation.providerID
          ))
      }
    }
    guard !sources.isEmpty else { throw ConversationHandoverError.unavailable }
    do {
      try manager.createDirectory(
        at: destination, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var index = "# Conversation history\n\nSession: \(session.name)\n\n"
      index += "Snapshot of the available native logs in conversation order. Each file is JSONL. "
      index += "Sub-agent files are labelled by their original filename. "
      index += "An incomplete final record may be present if a CLI was writing during the copy.\n\n"
      if !missing.isEmpty {
        index +=
          "Unavailable conversations (history is partial): \(missing.joined(separator: ", "))\n\n"
      }
      var bytes = 0
      var offset = 0
      while offset < sources.count {
        let source = sources[offset]
        offset += 1
        let filename = "\(offset).jsonl"
        let copy = destination.appendingPathComponent(filename)
        bytes += try snapshot(source.file, to: copy)
        // Paths in JSON strings are unambiguous even with spaces, quotes or newlines.
        let path = String(decoding: try JSONEncoder().encode(copy.path), as: UTF8.self)
        let original = String(
          decoding: try JSONEncoder().encode(source.file.lastPathComponent), as: UTF8.self)
        index += "- \(source.label); original filename: \(original); copied file: \(path)\n"
        if source.isCodex {
          for identifier in codexSubagents(in: copy).sorted() {
            let files = locator.codexRollouts(
              for: identifier, providerID: source.providerID, since: session.createdAt
            )
            .sorted { $0.path < $1.path }
            if files.isEmpty { index += "- Unavailable sub-agent: \(identifier)\n" }
            for file in files where seen.insert(file.standardizedFileURL.path).inserted {
              sources.append(("codex / sub-agent / \(identifier)", file, true, source.providerID))
            }
          }
        }
      }
      guard bytes > 0 else { throw ConversationHandoverError.unavailable }
      let file = destination.appendingPathComponent("history.md")
      guard
        manager.createFile(
          atPath: file.path, contents: Data(index.utf8),
          attributes: [.posixPermissions: 0o600])
      else { throw ConversationHandoverError.cannotCopy }
      return ConversationHandover(index: file, byteCount: bytes)
    } catch {
      try? manager.removeItem(at: destination)
      if let known = error as? ConversationHandoverError { throw known }
      throw ConversationHandoverError.cannotCopy
    }
  }

  /// Discover Codex children from the copied snapshot, using the same activity records as the
  /// conversation reader. Only identifiers are retained, not a decoded conversation in memory.
  private func codexSubagents(in file: URL) -> Set<String> {
    var reader = TranscriptLineReader(file: file)
    var identifiers: Set<String> = []
    while true {
      let result = FileTranscriptTail.readChunk(with: &reader)
      for record in result.records {
        let object = record.object
        guard object["type"] as? String == "event_msg",
          let payload = object["payload"] as? [String: Any],
          payload["type"] as? String == "item_completed",
          let item = payload["item"] as? [String: Any],
          item["type"] as? String == "SubAgentActivity",
          let identifier = item["agent_thread_id"] as? String ?? item["id"] as? String,
          !identifier.isEmpty, !identifier.contains("/"), !identifier.contains("..")
        else { continue }
        identifiers.insert(identifier)
      }
      if !result.reading.hasMore { return identifiers }
    }
  }

  /// Bound the read to the size at open, even if the active CLI keeps appending. Never load an
  /// entire conversation into memory, and never follow a symbolic link supplied as a transcript.
  private func snapshot(_ source: URL, to destination: URL) throws -> Int {
    let descriptor = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw ConversationHandoverError.cannotCopy }
    let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? input.close() }
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0,
      (attributes.st_mode & S_IFMT) == S_IFREG
    else { throw ConversationHandoverError.cannotCopy }
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
