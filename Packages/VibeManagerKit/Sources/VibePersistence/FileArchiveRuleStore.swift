import Foundation
import VibeApplication

/// The automatic archive's rules, in `Automation/archive-rules.json` in the data folder (#405).
///
/// Every change is made under `archive-rules.lock`, shared by every copy of the application:
/// read, check, write, then let go. A time a rule is due is claimed that way before it runs, so
/// that two copies never run it twice. A document this version cannot read is never written over.
public actor FileArchiveRuleStore: ArchiveRuleStore {
  static let currentFormat = 1
  static let lockFileName = "archive-rules.lock"
  /// Long enough for another copy's change, which is a read and a write of a small file.
  static let lockTimeout: Duration = .seconds(5)

  public struct Unreadable: Error {}
  public struct Busy: Error {}

  private let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// `Automation/archive-rules.json` in the folder that holds `sessions.json`.
  public static func defaultURL(dataFolder: URL) -> URL {
    dataFolder.appendingPathComponent("Automation", isDirectory: true)
      .appendingPathComponent("archive-rules.json", isDirectory: false)
  }

  public func load() throws -> ArchiveRuleSet {
    try locked { try read() }
  }

  @discardableResult
  public func update(_ change: @escaping @Sendable (inout ArchiveRuleSet) throws -> Void) throws
    -> ArchiveRuleSet
  {
    try locked {
      var set = try read()
      let before = set
      try change(&set)
      guard set != before else { return set }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      try AtomicFileWriter.write(
        try encoder.encode(Document(format: Self.currentFormat, set: set)), to: url)
      return set
    }
  }

  private func read() throws -> ArchiveRuleSet {
    guard FileManager.default.fileExists(atPath: url.path) else { return ArchiveRuleSet() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let document = try? decoder.decode(Document.self, from: Data(contentsOf: url)),
      document.format == Self.currentFormat
    else { throw Unreadable() }
    return document.set
  }

  /// Runs `body` holding the lock, never waiting for it forever.
  private func locked<T>(_ body: () throws -> T) throws -> T {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = directory.appendingPathComponent(Self.lockFileName).path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    let deadline = ContinuousClock.now + Self.lockTimeout
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      guard code == EWOULDBLOCK || code == EINTR else {
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
      guard ContinuousClock.now < deadline else { throw Busy() }
      usleep(10_000)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  private struct Document: Codable {
    let format: Int
    let notifies: Bool
    let rules: [Rule]
    let protections: [StoredArchiveProtection]

    init(format: Int, set: ArchiveRuleSet) {
      self.format = format
      notifies = set.notifies
      rules = set.rules.map(Rule.init)
      protections = set.protections
    }

    var set: ArchiveRuleSet {
      ArchiveRuleSet(
        rules: rules.map(\.domainValue), protections: protections, notifies: notifies)
    }
  }

  /// A rule, its state spelled out: a state written by a later version reads as paused.
  private struct Rule: Codable {
    let id: UUID
    let text: String
    let state: String
    let sentence: String
    let agent: String
    let createdAt: Date
    let activatedAt: Date
    let lastHandled: Date?
    let lastRun: ArchiveRunResult?

    init(_ rule: StoredArchiveRule) {
      id = rule.id
      text = rule.text
      state = rule.state.rawValue
      sentence = rule.sentence
      agent = rule.agent
      createdAt = rule.createdAt
      activatedAt = rule.activatedAt
      lastHandled = rule.lastHandled
      lastRun = rule.lastRun
    }

    var domainValue: StoredArchiveRule {
      StoredArchiveRule(
        id: id, text: text, state: StoredArchiveRule.State(rawValue: state) ?? .paused,
        sentence: sentence, agent: agent, createdAt: createdAt, activatedAt: activatedAt,
        lastHandled: lastHandled, lastRun: lastRun)
    }
  }
}
