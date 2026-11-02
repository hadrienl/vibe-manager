import Foundation

/// A second account of Claude Code or Codex (#478): the same CLI, with another configuration
/// folder. The CLI keeps the sign-in, the transcripts and the settings there; nothing of the
/// account but its folder is known here.
///
/// The harness and the folder are fixed once created: the conversations of the account are in
/// that folder, and would not be found from another.
public struct AgentAccount: Identifiable, Hashable, Codable, Sendable {
  public static let providerPrefix = "account."

  public let id: UUID
  public var name: String
  public let harness: EndpointHarness
  /// As the user typed it: absolute, or from `~/`.
  public let configurationDirectory: String

  public init(
    id: UUID = UUID(), name: String, harness: EndpointHarness, configurationDirectory: String
  ) {
    self.id = id
    self.name = name
    self.harness = harness
    self.configurationDirectory = configurationDirectory
  }

  /// The identifier the account is registered under among the agents.
  public var providerID: String { Self.providerPrefix + id.uuidString }

  /// The folder the CLI uses when told nothing, from the home folder.
  public static func defaultComponent(of harness: EndpointHarness) -> String {
    switch harness {
    case .claudeCode: return ".claude"
    case .codex: return ".codex"
    }
  }

  /// The absolute path of a folder as typed; `nil` when it means nothing outside a shell.
  public static func resolvedDirectory(_ typed: String, home: String) -> String? {
    var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if path == "~" || path.hasPrefix("~/") {
      path = home + path.dropFirst(1)
    }
    guard path.hasPrefix("/") else { return nil }
    let standardized = (path as NSString).standardizingPath
    return standardized == "/" ? nil : standardized
  }

  public enum ValidationIssue: Hashable, Sendable {
    case noName
    case directoryNotAbsolute
    /// The folder of the CLI's own agent: it would be the same account.
    case directoryIsDefault
    /// Already another account's, of the same CLI.
    case directoryTaken(name: String)
  }

  /// What prevents the account from being saved beside `others`, the most useful first.
  public func validationIssues(
    among others: [AgentAccount], home: String, defaultDirectory: String? = nil
  ) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.noName) }
    guard let directory = Self.resolvedDirectory(configurationDirectory, home: home) else {
      return issues + [.directoryNotAbsolute]
    }
    let fallback = (home as NSString).appendingPathComponent(Self.defaultComponent(of: harness))
    if directory == (defaultDirectory ?? fallback) { issues.append(.directoryIsDefault) }
    if let other = others.first(where: {
      $0.id != id && $0.harness == harness
        && Self.resolvedDirectory($0.configurationDirectory, home: home) == directory
    }) {
      issues.append(.directoryTaken(name: other.name))
    }
    return issues
  }
}
