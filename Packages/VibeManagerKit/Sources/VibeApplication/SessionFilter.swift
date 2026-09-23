import Foundation
import VibeDomain

/// Which part of the history a view is looking at.
///
/// The split is "is something running here", not "has this been archived". Those are two
/// different questions: the first is what the user is doing right now, the second is whether a
/// finished session may be picked up again. Archiving therefore does not move a session between
/// the two — a closed session and an archived one are both done — it decides whether the one in
/// the closed list can be reopened.
public enum SessionScope: String, Codable, CaseIterable, Sendable {
  /// Sessions with a live agent.
  case active
  /// Everything that is finished, archived or not.
  case closed

  public var label: String {
    switch self {
    case .active: return "Active"
    case .closed: return "Closed"
    }
  }

  public func includes(_ status: SessionStatus) -> Bool {
    switch self {
    case .active: return status == .active
    case .closed: return status != .active
    }
  }
}

public enum SessionSort: String, Codable, CaseIterable, Sendable {
  case lastActivity
  case created
  case name

  public var label: String {
    switch self {
    case .lastActivity: return "Last Activity"
    case .created: return "Date Created"
    case .name: return "Name"
    }
  }
}

/// What the sidebar shows, as a value.
///
/// The rule lives here rather than in the view so that the list, the archive count and the tests
/// all read the same one. `apply(to:)` is pure: the same store and the same filter always draw
/// the same list, in the same order, which is what makes the order survive a restart.
public struct SessionFilter: Equatable, Sendable, Codable {
  public var scope: SessionScope
  public var sort: SessionSort
  /// Deliberately not persisted. Scope and sort are settings; a half-typed query is an action in
  /// progress, and finding it still applied three days later would look like an empty store.
  public var searchText: String
  public var agentProviderIDs: Set<String>
  public var repositoryPath: String?

  public init(
    scope: SessionScope = .active,
    sort: SessionSort = .lastActivity,
    searchText: String = "",
    agentProviderIDs: Set<String> = [],
    repositoryPath: String? = nil
  ) {
    self.scope = scope
    self.sort = sort
    self.searchText = searchText
    self.agentProviderIDs = agentProviderIDs
    self.repositoryPath = repositoryPath
  }

  private enum CodingKeys: String, CodingKey {
    case scope, sort, agentProviderIDs, repositoryPath
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Each field is decoded on its own terms, and a value this build does not know falls back
    // rather than throwing. A scope written by a later version must cost the user their sort
    // order at worst — thrown from here, it would take the whole layout down with it, columns,
    // widths and selection included.
    self.init(
      scope: (try? container.decodeIfPresent(SessionScope.self, forKey: .scope)) ?? .active,
      sort: (try? container.decodeIfPresent(SessionSort.self, forKey: .sort)) ?? .lastActivity,
      agentProviderIDs: (try? container.decodeIfPresent(
        Set<String>.self, forKey: .agentProviderIDs)) ?? [],
      repositoryPath: try? container.decodeIfPresent(String.self, forKey: .repositoryPath)
    )
  }

  /// Whether anything beyond the scope is hiding sessions. The empty state uses it to tell
  /// "nothing archived yet" from "nothing matches what you typed".
  public var isNarrowing: Bool {
    !trimmedSearchText.isEmpty || !agentProviderIDs.isEmpty || repositoryPath != nil
  }

  public var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func apply(to sessions: [WorkSession]) -> [WorkSession] {
    sessions.filter(matches).sorted(by: ordering)
  }

  public func matches(_ session: WorkSession) -> Bool {
    guard scope.includes(session.status) else { return false }

    if !agentProviderIDs.isEmpty {
      guard let providerID = session.agent?.providerID, agentProviderIDs.contains(providerID)
      else {
        return false
      }
    }

    if let repositoryPath {
      guard session.repositories.contains(where: { $0.rootPath == repositoryPath }) else {
        return false
      }
    }

    let query = trimmedSearchText
    guard !query.isEmpty else { return true }

    // `localizedStandardContains` is the search a Finder user already knows: case and accents are
    // ignored, so "refacto" finds "Réfactoring" without the user learning a syntax.
    var haystack = [session.name, session.initialPrompt]
    if let notes = session.notes { haystack.append(notes) }
    for repository in session.repositories {
      haystack.append(repository.rootPath)
      if let worktreePath = repository.worktreePath { haystack.append(worktreePath) }
      if let branchName = repository.branchName { haystack.append(branchName) }
    }
    return haystack.contains { $0.localizedStandardContains(query) }
  }

  /// Every ordering ends on the identifier, so it is total: two sessions can share a name or a
  /// timestamp, and the list must still come back in the same order at the next launch.
  private func ordering(_ lhs: WorkSession, _ rhs: WorkSession) -> Bool {
    switch sort {
    case .lastActivity:
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    case .created:
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
    case .name:
      let comparison = lhs.name.localizedStandardCompare(rhs.name)
      if comparison != .orderedSame { return comparison == .orderedAscending }
    }
    return lhs.id.description < rhs.id.description
  }
}

extension SessionFilter {
  /// The facets worth offering, taken from the sessions that exist rather than from a fixed list:
  /// an agent nobody uses here has no reason to appear in the menu.
  public static func availableProviderIDs(in sessions: [WorkSession]) -> [String] {
    Set(sessions.compactMap { $0.agent?.providerID }).sorted()
  }

  public static func availableRepositoryPaths(in sessions: [WorkSession]) -> [String] {
    Set(sessions.flatMap { $0.repositories.map(\.rootPath) }).sorted()
  }

  /// Drops the facets that no longer name anything.
  ///
  /// A filter restored from a previous run can point at an agent that has been uninstalled or a
  /// folder that no longer has sessions. Keeping it would show an empty sidebar with no visible
  /// reason, which reads as a lost store rather than as a filter.
  public func reconciled(with sessions: [WorkSession]) -> SessionFilter {
    var reconciled = self
    let providers = Set(Self.availableProviderIDs(in: sessions))
    reconciled.agentProviderIDs = agentProviderIDs.intersection(providers)
    if let repositoryPath, !Self.availableRepositoryPaths(in: sessions).contains(repositoryPath) {
      reconciled.repositoryPath = nil
    }
    return reconciled
  }
}
