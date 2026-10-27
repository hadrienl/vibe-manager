import Foundation

/// Where the agents create the worktree of a task (#432): text and variables, as Settings ›
/// Worktrees builds it. Vibe Manager creates nothing in git; it gives the path to the agents.
///
/// Stored as text, each variable written `{name}`: `{repo}/.claude/worktrees/{branch}`.
public struct WorktreeLocation: Hashable, Codable, Sendable {
  public enum Variable: String, CaseIterable, Hashable, Codable, Sendable {
    /// The folder of the main repository, not of one of its worktrees.
    case repository = "repo"
    /// The name of that folder.
    case project
    /// The worktree's branch, each `/` replaced by `-`.
    case branch
    /// The number of the ticket the task works on, or else the branch.
    case ticket
    /// The session's name, as a folder's.
    case session
    /// The agent running the session: `claude-code`, `codex`.
    case agent
    /// The day the worktree is created, `2026-10-27`.
    case date

    /// A variable that tells two tasks apart: without one, they would share a folder.
    public var isDistinctive: Bool {
      switch self {
      case .branch, .ticket, .session: true
      case .repository, .project, .agent, .date: false
      }
    }
  }

  public enum Part: Hashable, Sendable {
    case text(String)
    case variable(Variable)
  }

  /// Text parts never follow one another, and none is empty.
  public private(set) var parts: [Part]

  public init(parts: [Part]) {
    var merged: [Part] = []
    for part in parts {
      switch (merged.last, part) {
      case (_, .text("")): continue
      case (.text(let previous)?, .text(let next)): merged[merged.count - 1] = .text(previous + next)
      default: merged.append(part)
      }
    }
    self.parts = merged
  }

  /// `{repo}/.claude/worktrees/{branch}`: an unknown `{name}` stays text.
  public init(template: String) {
    var parts: [Part] = []
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
      parts.append(.text(String(rest[..<open])))
      let after = rest[rest.index(after: open)...]
      if let close = after.firstIndex(of: "}"), let variable = Variable(rawValue: String(after[..<close])) {
        parts.append(.variable(variable))
        rest = after[after.index(after: close)...]
      } else {
        parts.append(.text("{"))
        rest = after
      }
    }
    parts.append(.text(String(rest)))
    self.init(parts: parts)
  }

  public var template: String {
    parts.map { part in
      switch part {
      case .text(let text): text
      case .variable(let variable): "{\(variable.rawValue)}"
      }
    }.joined()
  }

  public var isEmpty: Bool { parts.isEmpty }

  public init(from decoder: any Decoder) throws {
    self.init(template: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(template)
  }

  /// The path with the variables `values` gives replaced; the others are left as `{name}`.
  public func resolved(_ values: [Variable: String]) -> String {
    parts.map { part in
      switch part {
      case .text(let text): text
      case .variable(let variable): values[variable] ?? "{\(variable.rawValue)}"
      }
    }.joined()
  }

  // MARK: Presets

  public enum Preset: String, CaseIterable, Hashable, Sendable {
    /// `{repo}/.claude/worktrees/{branch}`, where Claude Code puts its own.
    case insideRepository
    /// `{repo}-{ticket}`, beside the repository.
    case besideRepository
    /// `~/Worktrees/{project}/{branch}`, one folder for every repository.
    case commonFolder

    public var location: WorktreeLocation {
      switch self {
      case .insideRepository:
        WorktreeLocation(parts: [
          .variable(.repository), .text("/.claude/worktrees/"), .variable(.branch),
        ])
      case .besideRepository:
        WorktreeLocation(parts: [.variable(.repository), .text("-"), .variable(.ticket)])
      case .commonFolder:
        WorktreeLocation(parts: [
          .text("~/Worktrees/"), .variable(.project), .text("/"), .variable(.branch),
        ])
      }
    }
  }

  public static let `default` = Preset.insideRepository.location

  /// The preset this is, `nil` for one of the user's own.
  public var preset: Preset? {
    Preset.allCases.first { $0.location == self }
  }

  // MARK: Guards

  public enum Warning: Hashable, Sendable {
    /// No path: the agents choose where.
    case empty
    /// Neither the branch, the ticket nor the session: two tasks would share a folder.
    case notDistinctive
    /// Neither `~`, `/` nor the repository first: a path relative to wherever the agent is.
    case notAbsolute
  }

  public var warning: Warning? {
    guard let first = parts.first else { return .empty }
    guard parts.contains(where: { if case .variable(let v) = $0 { v.isDistinctive } else { false } })
    else { return .notDistinctive }
    switch first {
    case .variable(.repository): return nil
    case .text(let text) where text.hasPrefix("~") || text.hasPrefix("/"): return nil
    default: return .notAbsolute
    }
  }

  /// Whether the path lies inside the repository, `{repo}/…`: the agent then keeps it out of
  /// `git status` through `.git/info/exclude`.
  public var isInsideRepository: Bool {
    guard parts.count > 1, case .variable(.repository) = parts[0], case .text(let text) = parts[1]
    else { return false }
    return text.hasPrefix("/")
  }

  /// `feat/432-worktree` as a folder's name: `feat-432-worktree`.
  public static func folderName(branch: String) -> String {
    branch.replacingOccurrences(of: "/", with: "-")
  }

  /// A session's name as a folder's: lower case, words joined by `-`, nothing but letters and
  /// digits.
  public static func folderName(session name: String) -> String {
    let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .lowercased()
    let words = folded.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
    return words.joined(separator: "-")
  }
}

/// Settings › Worktrees: the path for every repository, and the repositories with their own.
public struct WorktreeLocationSettings: Hashable, Codable, Sendable {
  public var general: WorktreeLocation
  /// Keyed by the main repository's folder, standardized.
  public var exceptions: [String: WorktreeLocation]

  public init(
    general: WorktreeLocation = .default, exceptions: [String: WorktreeLocation] = [:]
  ) {
    self.general = general
    self.exceptions = exceptions
  }

  /// The path for `repository`, a main repository's folder.
  public func location(for repository: String?) -> WorktreeLocation {
    repository.flatMap { exceptions[($0 as NSString).standardizingPath] } ?? general
  }
}
