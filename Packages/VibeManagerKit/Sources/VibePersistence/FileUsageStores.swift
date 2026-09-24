import Foundation
import VibeApplication
import VibeDomain

/// `Usage/` next to `sessions.json`: the run journal, the heartbeat, the token totals and the
/// tracking intervals. Files are `0600`, and a folder created here is `0700`.
public enum UsageStorage {
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Usage", isDirectory: true)
  }

  static func ensureDirectory(_ directory: URL) throws {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: directory.path) else { return }
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  /// A unique temporary file in the same folder, synchronized, then moved over: a crash leaves
  /// the old version or the new one.
  static func atomicWrite(_ data: Data, to destination: URL) throws {
    let manager = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try ensureDirectory(directory)
    let temporaryURL = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryURL) }
    guard
      manager.createFile(
        atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteNoPermission) }
    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
    } catch {
      try? handle.close()
      throw error
    }
    try handle.close()
    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try manager.moveItem(at: temporaryURL, to: destination)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      pretty
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(timestampFormatter().string(from: date))
    }
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      guard let date = timestampFormatter().date(from: value) else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(codingPath: decoder.codingPath, debugDescription: value))
      }
      // Back to the precision it was written with, so a value read compares equal to the one
      // that was stored.
      return date.storageRounded
    }
    return decoder
  }

  private static func timestampFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}

// MARK: - Run journal

/// The run journal, one file per month, one event per line.
///
/// Appended to rather than rewritten: a line costs the same whatever the history, and a month
/// holds a few kilobytes. A last line cut short by a crash is ignored when read.
public actor FileUsageLedger: UsageLedger {
  private let directory: URL
  private let calendar: Calendar

  public init(directory: URL = UsageStorage.defaultDirectory(), calendar: Calendar = .current) {
    self.directory = directory
    self.calendar = calendar
  }

  public func append(_ event: UsageLedgerEvent) throws {
    try UsageStorage.ensureDirectory(directory)
    var line = try UsageStorage.encoder().encode(LedgerLine(event))
    line.append(UInt8(ascii: "\n"))
    let url = journalURL(for: event.date)
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    fsync(descriptor)
  }

  public func events() throws -> [UsageLedgerEvent] {
    let decoder = UsageStorage.decoder()
    var events: [UsageLedgerEvent] = []
    for url in journalURLs() {
      guard let data = try? Data(contentsOf: url) else { continue }
      for line in data.split(separator: UInt8(ascii: "\n")) {
        guard let decoded = try? decoder.decode(LedgerLine.self, from: Data(line)),
          let event = decoded.event
        else { continue }
        events.append(event)
      }
    }
    // Months in order, and inside a month the order they were written in.
    return events
  }

  public func writeHeartbeat(_ heartbeat: UsageHeartbeat?) throws {
    let url = directory.appendingPathComponent("heartbeat.json")
    guard let heartbeat else {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return
    }
    try UsageStorage.atomicWrite(try UsageStorage.encoder().encode(heartbeat), to: url)
  }

  public func heartbeat() -> UsageHeartbeat? {
    let url = directory.appendingPathComponent("heartbeat.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? UsageStorage.decoder().decode(UsageHeartbeat.self, from: data)
  }

  public func clear() throws {
    let manager = FileManager.default
    for url in journalURLs() { try manager.removeItem(at: url) }
    try writeHeartbeat(nil)
  }

  func journalURL(for date: Date) -> URL {
    let parts = calendar.dateComponents([.year, .month], from: date)
    let name = String(format: "runs-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0)
    return directory.appendingPathComponent(name)
  }

  private func journalURLs() -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasPrefix("runs-") && $0.hasSuffix(".jsonl") }.sorted()
      .map { directory.appendingPathComponent($0) }
  }
}

/// One line of the journal. An allowlist: identifiers, slugs, kinds and dates.
struct LedgerLine: Codable {
  var type: String
  var at: Date
  var runID: UUID?
  var sessionID: UUID?
  var providerID: String?
  var modelID: String?
  var kind: UsageRunKind?
  var afterRelaunch: Bool?
  var afterSwitch: Bool?
  var exit: UsageRunExit?

  init(_ event: UsageLedgerEvent) {
    switch event {
    case .start(let run):
      type = "start"
      at = run.startedAt
      runID = run.id
      sessionID = run.sessionID.rawValue
      providerID = run.providerID
      modelID = run.modelID
      kind = run.kind
      afterRelaunch = run.afterRelaunch
      afterSwitch = run.afterSwitch
    case .end(let id, let date, let exit):
      type = "end"
      at = date
      runID = id
      self.exit = exit
    case .detach(let id, let date):
      type = "detach"
      at = date
      runID = id
    case .attach(let id, let date):
      type = "attach"
      at = date
      runID = id
    case .suspend(let date):
      type = "suspend"
      at = date
    case .resume(let date):
      type = "resume"
      at = date
    }
  }

  var event: UsageLedgerEvent? {
    switch type {
    case "start":
      guard let runID, let sessionID, let providerID, let kind else { return nil }
      return .start(
        UsageRun(
          id: runID, sessionID: SessionID(rawValue: sessionID), providerID: providerID,
          modelID: modelID, kind: kind, afterRelaunch: afterRelaunch ?? false,
          afterSwitch: afterSwitch ?? false, startedAt: at))
    case "end":
      guard let runID else { return nil }
      return .end(runID: runID, at: at, exit: exit ?? .stopped)
    case "detach":
      guard let runID else { return nil }
      return .detach(runID: runID, at: at)
    case "attach":
      guard let runID else { return nil }
      return .attach(runID: runID, at: at)
    case "suspend":
      return .suspend(at: at)
    case "resume":
      return .resume(at: at)
    default:
      return nil
    }
  }
}

// MARK: - Tracking intervals

public actor FileUsageTrackingStore: UsageTrackingStore {
  private let url: URL

  public init(directory: URL = UsageStorage.defaultDirectory()) {
    url = directory.appendingPathComponent("tracking.json")
  }

  /// Without a file, tracking is on and always was.
  public func intervals() -> [UsageTrackingInterval] {
    guard let data = try? Data(contentsOf: url),
      let document = try? UsageStorage.decoder().decode(Document.self, from: data)
    else { return [UsageTrackingInterval(from: .distantPast)] }
    return document.intervals
  }

  public func save(_ intervals: [UsageTrackingInterval]) throws {
    try UsageStorage.atomicWrite(
      try UsageStorage.encoder(pretty: true).encode(Document(intervals: intervals)), to: url)
  }

  struct Document: Codable {
    var version = 1
    var intervals: [UsageTrackingInterval]
  }
}

// MARK: - Token totals

public actor FileTokenUsageStore: TokenUsageStore {
  private let url: URL

  public init(directory: URL = UsageStorage.defaultDirectory()) {
    url = directory.appendingPathComponent("tokens.json")
  }

  public func load() -> TokenUsageSnapshot {
    guard let data = try? Data(contentsOf: url),
      let document = try? UsageStorage.decoder().decode(Document.self, from: data),
      document.version == 1
    else { return .empty }
    return document.snapshot
  }

  public func save(_ snapshot: TokenUsageSnapshot) throws {
    try UsageStorage.atomicWrite(
      try UsageStorage.encoder().encode(Document(snapshot: snapshot)), to: url)
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  struct Document: Codable {
    var version = 1
    var snapshot: TokenUsageSnapshot
  }
}
