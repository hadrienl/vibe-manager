import Foundation

/// What one run of a rule did, shown on its line in the Settings.
public struct ArchiveRunResult: Hashable, Codable, Sendable {
  public var date: Date
  public var archived: Int
  public var skipped: Int
  /// A run of a rule on trial: `archived` is what it would have archived.
  public var isTrial: Bool

  public init(date: Date, archived: Int, skipped: Int, isTrial: Bool) {
    self.date = date
    self.archived = archived
    self.skipped = skipped
    self.isTrial = isTrial
  }
}

/// A rule as the store keeps it: its text, and where it stands.
public struct StoredArchiveRule: Identifiable, Hashable, Codable, Sendable {
  public enum State: String, Codable, Sendable, CaseIterable {
    case active
    /// Runs without archiving: its line says what it would have archived.
    case trial
    case paused
  }

  public let id: UUID
  /// One `rule` block of the language.
  public var text: String
  public var state: State
  /// The sentence it was made from, and the agent that translated it: what Redo starts from.
  public var sentence: String
  public var agent: String
  public var createdAt: Date
  /// When it was last turned on: where `every` counts from, and the first time it may run after.
  public var activatedAt: Date
  /// The last time it was due and handled — run, or passed over by `no catch-up`. Claimed
  /// before the run, so that two copies of the application never run the same time twice.
  public var lastHandled: Date?
  public var lastRun: ArchiveRunResult?

  public init(
    id: UUID = UUID(), text: String, state: State, sentence: String, agent: String,
    createdAt: Date, activatedAt: Date, lastHandled: Date? = nil, lastRun: ArchiveRunResult? = nil
  ) {
    self.id = id
    self.text = text
    self.state = state
    self.sentence = sentence
    self.agent = agent
    self.createdAt = createdAt
    self.activatedAt = activatedAt
    self.lastHandled = lastHandled
    self.lastRun = lastRun
  }

  /// The rule, or `nil` when the text does not read as one rule any more — written by a later
  /// version, or changed outside the application. Such a rule never runs, and says so.
  public var rule: ArchiveRule? {
    guard let document = try? ArchiveRuleParser.parse(text), document.protections.isEmpty,
      document.rules.count == 1
    else { return nil }
    return document.rules[0]
  }

  /// Whether it runs: turned on or on trial, and readable.
  public var runs: Bool {
    state != .paused && rule != nil
  }
}

/// A protection as the store keeps it.
public struct StoredArchiveProtection: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  /// One `protect` line of the language.
  public var text: String
  public var sentence: String

  public init(id: UUID = UUID(), text: String, sentence: String) {
    self.id = id
    self.text = text
    self.sentence = sentence
  }

  public var protection: ArchiveProtection? {
    guard let document = try? ArchiveRuleParser.parse(text), document.rules.isEmpty,
      document.protections.count == 1
    else { return nil }
    return document.protections[0]
  }
}

/// Everything the automatic archive keeps: user data, so in the data folder rather than in the
/// preferences.
public struct ArchiveRuleSet: Hashable, Codable, Sendable {
  public var rules: [StoredArchiveRule]
  public var protections: [StoredArchiveProtection]
  /// A notification after each run that archives something.
  public var notifies: Bool

  public init(
    rules: [StoredArchiveRule] = [], protections: [StoredArchiveProtection] = [],
    notifies: Bool = true
  ) {
    self.rules = rules
    self.protections = protections
    self.notifies = notifies
  }

  /// The protections that read. One that does not read protects nothing it cannot name, but it
  /// keeps every rule from running: a rule never runs on a guess of what was meant.
  public var readableProtections: [ArchiveProtection]? {
    var result: [ArchiveProtection] = []
    for stored in protections {
      guard let protection = stored.protection else { return nil }
      result.append(protection)
    }
    return result
  }
}

/// Where the rules are kept. Every change reads, changes and writes under a lock that every copy
/// of the application shares.
public protocol ArchiveRuleStore: Sendable {
  func load() async throws -> ArchiveRuleSet
  @discardableResult
  func update(_ change: @escaping @Sendable (inout ArchiveRuleSet) throws -> Void) async throws
    -> ArchiveRuleSet
}

/// A store in memory, for tests and previews.
public actor InMemoryArchiveRuleStore: ArchiveRuleStore {
  private var set: ArchiveRuleSet

  public init(_ set: ArchiveRuleSet = ArchiveRuleSet()) {
    self.set = set
  }

  public func load() -> ArchiveRuleSet { set }

  @discardableResult
  public func update(_ change: @escaping @Sendable (inout ArchiveRuleSet) throws -> Void) throws
    -> ArchiveRuleSet
  {
    var copy = set
    try change(&copy)
    set = copy
    return set
  }
}
