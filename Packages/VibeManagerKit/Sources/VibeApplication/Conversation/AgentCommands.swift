import Foundation

/// A skill or a command the agent of a session runs when a prompt opens on it, as the composer
/// lists them under `/` (#219).
public struct AgentCommand: Hashable, Sendable, Identifiable {
  public enum Kind: Int, Hashable, Sendable, Comparable {
    case skill
    case command

    public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Where it comes from, as far as the CLI tells.
  public enum Origin: Hashable, Sendable {
    /// The session's folder.
    case project
    case user
    /// Named after the plugin that brings it: `prisme-ai`, `anthropic-skills`.
    case plugin(String)
    /// Shipped with the CLI as a skill: Codex's `.system` ones.
    case system
    /// One of the CLI's own commands.
    case builtin

    /// Project, user, plugins, system, built in: the order of the list before any filter.
    var rank: Int {
      switch self {
      case .project: return 0
      case .user: return 1
      case .plugin: return 2
      case .system: return 3
      case .builtin: return 4
      }
    }
  }

  public var id: String { invocation }
  /// `prisme-ai:debug-events`.
  public let name: String
  /// What the composer inserts, and the agent reads: `/prisme-ai:debug-events` for Claude Code,
  /// `$imagegen` for a skill of Codex, which invokes its skills with `$`.
  public let invocation: String
  public let description: String
  /// What the command expects after its name — `[correlationId]` — shown dimmed once inserted.
  public let argumentHint: String?
  public let kind: Kind
  /// `nil` when neither the CLI nor its folders say.
  public let origin: Origin?
  /// Other names the CLI accepts for it: `/review` for `/code-review`.
  public let aliases: [String]

  public init(
    name: String, invocation: String, description: String, argumentHint: String? = nil,
    kind: Kind, origin: Origin?, aliases: [String] = []
  ) {
    self.name = name
    self.invocation = invocation
    self.description = description
    let hint = argumentHint?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.argumentHint = hint?.isEmpty == false ? hint : nil
    self.kind = kind
    self.origin = origin
    self.aliases = aliases
  }

  /// The character the agent reads it by: `/` or `$`.
  public var trigger: Character { invocation.first ?? "/" }
}

/// What the CLI of an agent listed, with the skills it could not read.
public struct AgentCommandList: Hashable, Sendable {
  public var commands: [AgentCommand]
  /// Skills the CLI found but refused — a front matter it could not read — for the diagnostics:
  /// they never keep the others from the list.
  public var problems: [AgentCommandProblem]

  public init(commands: [AgentCommand], problems: [AgentCommandProblem] = []) {
    self.commands = commands
    self.problems = problems
  }
}

public struct AgentCommandProblem: Hashable, Sendable {
  public let path: String
  public let message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

/// Implemented by the providers whose CLI can say what a prompt may invoke (#219). A provider that
/// does not has no list: `/` is then text like any other.
public protocol AgentCommandListing: Sendable {
  /// Everything the agent started in `workingDirectoryPath` accepts, read from the CLI itself, with
  /// the configuration the agent reads. `refresh` asks a CLI that caches its skills to read them
  /// again.
  func commands(inWorkingDirectory workingDirectoryPath: String, refresh: Bool) async throws
    -> AgentCommandList
}

// MARK: - Search

/// The command being typed: the whole draft is a trigger then a name, without a space (#219).
public struct AgentCommandQuery: Hashable, Sendable {
  public let trigger: Character
  /// What follows the trigger.
  public let text: String

  /// The draft opens — blanks aside — on one of `triggers` followed by anything but a blank: a
  /// space typed after the name, or a line, and the command is written.
  public init?(draft: String, triggers: Set<Character>) {
    let token = draft.drop { $0 == " " || $0 == "\t" }
    guard let first = token.first, triggers.contains(first) else { return nil }
    let rest = token.dropFirst()
    guard !rest.contains(where: \.isWhitespace) else { return nil }
    trigger = first
    text = String(rest)
  }

  /// The draft once `command` is chosen: its invocation and a space, the blanks before it kept.
  public static func draft(inserting command: AgentCommand, into draft: String) -> String {
    let blanks = draft.prefix { $0 == " " || $0 == "\t" }
    return blanks + command.invocation + " "
  }
}

/// One entry of the list, with the parts of it the query found.
public struct AgentCommandMatch: Hashable, Sendable, Identifiable {
  public var id: String { command.id }
  public let command: AgentCommand
  /// Character offsets in `command.name`.
  public let nameRanges: [Range<Int>]
  /// Character offsets in `command.description`.
  public let descriptionRanges: [Range<Int>]
}

/// The list under `/`: what a query keeps, in the order shown, grouped as skills then commands.
///
/// Pure and quick — it runs at each key typed, on the main actor, over a few hundred entries — so
/// the commands are folded once, when the list is read, not at each search.
public struct AgentCommandIndex: Sendable {
  public let commands: [AgentCommand]
  private let entries: [Entry]

  private struct Entry: Sendable {
    let command: AgentCommand
    let name: String
    let aliases: [String]
    let description: String
    /// Whether folding kept every character where it was, for the parts found to be shown.
    let nameAligned: Bool
    let descriptionAligned: Bool
  }

  public init(_ commands: [AgentCommand]) {
    // Skills, then commands; within each, by origin, then by name.
    let ordered = commands.sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
      let left = lhs.origin?.rank ?? 5
      let right = rhs.origin?.rank ?? 5
      if left != right { return left < right }
      return Self.fold(lhs.name) < Self.fold(rhs.name)
    }
    self.commands = ordered
    entries = ordered.map { command in
      let name = Self.fold(command.name)
      let description = Self.fold(command.description)
      return Entry(
        command: command, name: name,
        aliases: command.aliases.map(Self.fold), description: description,
        nameAligned: name.count == command.name.count,
        descriptionAligned: description.count == command.description.count)
    }
  }

  public var isEmpty: Bool { commands.isEmpty }

  /// Which triggers open the list: `/` always, and `$` for an agent whose skills go by it.
  public var triggers: Set<Character> {
    Set(commands.map(\.trigger)).union(["/"])
  }

  /// What `query` keeps. `/` lists everything the agent accepts; another trigger — `$` — only
  /// what is invoked with it.
  ///
  /// Names that start with the text first, then a part of a namespaced name that does, an alias
  /// that does, a name that holds it, and last a description that holds it. Case and accents do
  /// not count.
  public func matches(for query: AgentCommandQuery) -> [AgentCommandMatch] {
    let text = Self.fold(query.text)
    let candidates = entries.filter { query.trigger == "/" || $0.command.trigger == query.trigger }
    guard !text.isEmpty else {
      return candidates.map {
        AgentCommandMatch(command: $0.command, nameRanges: [], descriptionRanges: [])
      }
    }
    var ranked: [(rank: Int, order: Int, match: AgentCommandMatch)] = []
    for (order, entry) in candidates.enumerated() {
      guard let (rank, match) = Self.match(entry, text) else { continue }
      ranked.append((rank, order, match))
    }
    // Grouped as unfiltered — skills, then commands — and by rank within each group.
    return ranked.sorted {
      let left = $0.match.command.kind
      let right = $1.match.command.kind
      if left != right { return left < right }
      return ($0.rank, $0.order) < ($1.rank, $1.order)
    }.map(\.match)
  }

  /// Whether ↩ completes the text typed into `command` rather than sending it: only when what is
  /// typed begins its name, a part of it after `:`, or an alias, without being one already. An
  /// entry found by its description, or a name typed in full, leaves ↩ to send the text as typed —
  /// `/context` stays `/context` when `/compact` speaks of context (#219).
  public func completes(_ query: AgentCommandQuery, with command: AgentCommand) -> Bool {
    let text = Self.fold(query.text)
    guard !text.isEmpty else { return true }
    let candidates = entries.filter { query.trigger == "/" || $0.command.trigger == query.trigger }
    if candidates.contains(where: { $0.name == text || $0.aliases.contains(text) }) {
      return false
    }
    guard let entry = candidates.first(where: { $0.command == command }) else { return false }
    if entry.name.hasPrefix(text) { return true }
    let segments = entry.name.split(separator: ":", omittingEmptySubsequences: false).dropFirst()
    if segments.contains(where: { $0.hasPrefix(text) }) { return true }
    return entry.aliases.contains { $0.hasPrefix(text) }
  }

  private static func match(_ entry: Entry, _ text: String) -> (Int, AgentCommandMatch)? {
    func found(_ rank: Int, name: [Range<Int>] = [], description: [Range<Int>] = [])
      -> (Int, AgentCommandMatch)
    {
      (
        rank,
        AgentCommandMatch(
          command: entry.command, nameRanges: entry.nameAligned ? name : [],
          descriptionRanges: entry.descriptionAligned ? description : [])
      )
    }
    let length = text.count
    if entry.name.hasPrefix(text) { return found(0, name: [0..<length]) }
    // A part of a namespaced name: `debug-events` in `prisme-ai:debug-events`.
    var start = 0
    for segment in entry.name.split(separator: ":", omittingEmptySubsequences: false) {
      if start > 0, segment.hasPrefix(text) { return found(1, name: [start..<start + length]) }
      start += segment.count + 1
    }
    if entry.aliases.contains(where: { $0.hasPrefix(text) }) { return found(2) }
    if let offset = offset(of: text, in: entry.name) {
      return found(3, name: [offset..<offset + length])
    }
    if let offset = offset(of: text, in: entry.description) {
      return found(4, description: [offset..<offset + length])
    }
    return nil
  }

  private static func offset(of text: String, in string: String) -> Int? {
    guard let range = string.range(of: text) else { return nil }
    return string.distance(from: string.startIndex, to: range.lowerBound)
  }

  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

// MARK: - Catalog

/// The lists read from the agents' CLIs, one per agent and folder, shared by the sessions that run
/// there (#219).
///
/// Reading one starts a process — 0.3 s for Codex, 1 s for Claude Code — so a list is kept and
/// handed back at once, then read again in the background when it is older than `freshness`: a
/// skill added on disk shows the next time the list opens. A reading that fails keeps what was
/// read before.
public actor AgentCommandCatalog {
  public struct Key: Hashable, Sendable {
    public let providerID: AgentProviderID
    public let workingDirectoryPath: String

    public init(providerID: AgentProviderID, workingDirectoryPath: String) {
      self.providerID = providerID
      self.workingDirectoryPath = workingDirectoryPath
    }
  }

  private struct Entry {
    var index: AgentCommandIndex?
    var readAt: ContinuousClock.Instant?
    var reading: Task<AgentCommandIndex?, Never>?
  }

  private let freshness: Duration
  private let diagnostics: any DiagnosticLog
  private let clock = ContinuousClock()
  private var entries: [Key: Entry] = [:]

  public init(
    freshness: Duration = .seconds(30), diagnostics: any DiagnosticLog = NullDiagnosticLog()
  ) {
    self.freshness = freshness
    self.diagnostics = diagnostics
  }

  /// What was read last, without reading.
  public func cached(_ key: Key) -> AgentCommandIndex? {
    entries[key]?.index
  }

  /// The list, read again first when it is older than `freshness`: the caller shows the cached one
  /// meanwhile. Several asking at once share one reading.
  public func refreshed(_ key: Key, from listing: any AgentCommandListing) async
    -> AgentCommandIndex?
  {
    var entry = entries[key] ?? Entry()
    if let reading = entry.reading { return await reading.value }
    if let readAt = entry.readAt, clock.now - readAt < freshness { return entry.index }
    // A list read before is read again from disk: the CLI's own cache would hand back the same.
    let refresh = entry.readAt != nil
    let diagnostics = diagnostics
    let reading = Task<AgentCommandIndex?, Never> {
      do {
        let list = try await listing.commands(
          inWorkingDirectory: key.workingDirectoryPath, refresh: refresh)
        for problem in list.problems {
          diagnostics.record(
            .agentProbe, .notice, "agent.commands.unreadable",
            ["path": .path(RedactedPath(problem.path))])
        }
        return AgentCommandIndex(list.commands)
      } catch {
        diagnostics.record(.agentProbe, .notice, "agent.commands.failed")
        return nil
      }
    }
    entry.reading = reading
    entries[key] = entry
    let index = await reading.value
    var done = entries[key] ?? Entry()
    done.reading = nil
    done.readAt = clock.now
    if let index { done.index = index }
    entries[key] = done
    return done.index
  }
}
