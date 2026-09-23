import Foundation

/// What a worktree starts from.
public enum RepositoryBase: String, Hashable, Codable, Sendable, CaseIterable {
  /// What the clone has checked out right now — the least surprising start, and the default.
  case head
  /// The branch `origin/HEAD` points at: the mainline, which a coordinated change across three
  /// repositories often wants rather than whatever each clone happens to be on.
  case defaultBranch
}

/// A way out of a conflict that the user picked. Offered by the plan, never applied on its own.
public enum RepositoryConflictChoice: Hashable, Sendable {
  /// The session's branch already exists and is checked out nowhere: put the worktree on it
  /// rather than creating it. The ordinary case of a session being picked up again.
  case useExistingBranch
  /// The session's branch is already checked out in this worktree: work there.
  case adoptWorktree(path: String)
  /// The clone has a detached `HEAD` and is attached in place: create the session's branch there.
  case createBranchInPlace
}

/// One folder the user designated for a draft, and how they want it attached.
public struct SessionDraftRepository: Hashable, Sendable, Identifiable {
  public let id: RepositoryID
  public var path: String
  /// `nil` is "whatever fits": a worktree for a Git repository, a plain folder otherwise.
  public var mode: RepositoryAttachmentMode?
  public var base: RepositoryBase
  /// The folder under the session's folder, when the one derived from the path is not wanted.
  public var subfolderName: String?
  public var choice: RepositoryConflictChoice?

  public init(
    id: RepositoryID = RepositoryID(),
    path: String,
    mode: RepositoryAttachmentMode? = nil,
    base: RepositoryBase = .head,
    subfolderName: String? = nil,
    choice: RepositoryConflictChoice? = nil
  ) {
    self.id = id
    self.path = path
    self.mode = mode
    self.base = base
    self.subfolderName = subfolderName
    self.choice = choice
  }

  public var resolvedPath: String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return (trimmed as NSString).expandingTildeInPath
  }
}

/// Everything the user fills in before a session exists.
///
/// A draft is never half a `WorkSession`: nothing is written until `CreateSession` turns a whole
/// draft into one. That is what lets Cancel leave no trace, with nothing to clean up afterwards.
public struct SessionDraft: Hashable, Sendable {
  public var name: String
  public var initialPrompt: String
  public var providerID: String?
  /// `nil` means "let the agent decide", which is a real answer: both CLIs read a default from
  /// their own configuration, and neither guarantees a model catalogue exists to choose from.
  public var modelID: String?
  /// `nil` means "not chosen yet", so the identity keeps following the name.
  public var appearance: SessionAppearance?
  /// The folders of the session, the main one first.
  public var repositories: [SessionDraftRepository]
  /// What the user typed in the slug field. `nil` while they have not touched it, so the slug
  /// keeps following the name — the behaviour expected of a derived field, until contradicted.
  public var customSlug: String?
  /// The six hex digits a title that yields no slug falls back to. Drawn once per draft, so the
  /// preview does not change under the user at every keystroke.
  public let slugFallback: String

  public init(
    name: String = "",
    initialPrompt: String = "",
    providerID: String? = nil,
    modelID: String? = nil,
    appearance: SessionAppearance? = nil,
    workingDirectoryPath: String? = nil,
    repositories: [SessionDraftRepository] = [],
    customSlug: String? = nil,
    slugFallback: String = SessionSlug.randomSuffix()
  ) {
    self.name = name
    self.initialPrompt = initialPrompt
    self.providerID = providerID
    self.modelID = modelID
    self.appearance = appearance
    var repositories = repositories
    if let workingDirectoryPath, repositories.isEmpty {
      repositories = [SessionDraftRepository(path: workingDirectoryPath)]
    }
    self.repositories = repositories
    self.customSlug = customSlug
    self.slugFallback = slugFallback
  }

  /// The main repository's folder, as typed. Setting it replaces that folder and keeps the
  /// others; setting `nil` removes it.
  public var workingDirectoryPath: String? {
    get { repositories.first?.path }
    set {
      switch (newValue, repositories.isEmpty) {
      case (nil, true):
        return
      case (nil, false):
        repositories.removeFirst()
      case (let path?, true):
        repositories = [SessionDraftRepository(path: path)]
      case (let path?, false):
        // A different folder is a different repository: the choices made for the previous one
        // — a mode, a base, a conflict answered — say nothing about this one.
        if repositories[0].path != path {
          repositories[0] = SessionDraftRepository(id: repositories[0].id, path: path)
        }
      }
    }
  }

  /// The slug as it stands: the one typed, or the one the name leads to.
  public var slugText: String {
    customSlug ?? SessionSlug.derived(fromTitle: name, fallback: { slugFallback }).rawValue
  }

  /// The slug, when it is a valid one.
  public var slug: SessionSlug? {
    SessionSlug(slugText)
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var trimmedPrompt: String {
    initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var effectiveAppearance: SessionAppearance {
    appearance ?? SessionAppearanceCatalog.derived(forName: name)
  }

  public var resolvedWorkingDirectoryPath: String? {
    repositories.first?.resolvedPath
  }

  /// The problems visible without touching the disk or the agents.
  ///
  /// All of them at once, never the first one: a form that reveals its problems one by one makes
  /// the user press Create three times to learn three things.
  public func validate() -> [SessionDraftIssue] {
    var issues: [SessionDraftIssue] = []

    if trimmedName.isEmpty {
      issues.append(.nameMissing)
    }
    if let path = resolvedWorkingDirectoryPath {
      if !path.hasPrefix("/") {
        issues.append(.workingDirectoryNotAbsolute)
      }
    } else {
      issues.append(.workingDirectoryMissing)
    }
    if providerID?.isEmpty ?? true {
      issues.append(.agentMissing)
    }
    if !isStorableAppearance {
      issues.append(.appearanceInvalid)
    }
    return issues
  }

  /// The session this draft becomes. Callers pass a validated draft; the value is still checked
  /// by `WorkSession.validate()` before it reaches the store.
  ///
  /// - Parameters:
  ///   - repositories: the repositories as they were prepared. Without them, every folder is
  ///     attached as it is, in place — which is what a draft is when nothing has inspected it.
  ///   - slug: given only when a repository is on the session's branch. A session of plain
  ///     folders and clones worked in place names no branch, and two of them may share a title.
  public func session(
    id: SessionID = SessionID(),
    createdAt: Date = Date(),
    repositories prepared: [RepositoryContext]? = nil,
    slug: SessionSlug? = nil
  ) -> WorkSession {
    let repositories =
      prepared
      ?? repositories.compactMap { draft in
        draft.resolvedPath.map {
          RepositoryContext(id: draft.id, rootPath: $0, mode: .inPlace, attachedAt: createdAt)
        }
      }
    return WorkSession(
      id: id,
      name: trimmedName,
      initialPrompt: initialPrompt,
      agent: providerID.map { SessionAgentConfiguration(providerID: $0, modelID: modelID) },
      appearance: effectiveAppearance,
      status: .closed,
      createdAt: createdAt,
      updatedAt: createdAt,
      closedAt: createdAt,
      repositories: repositories,
      slug: slug
    )
  }

  private var isStorableAppearance: Bool {
    let appearance = effectiveAppearance
    guard !appearance.symbolName.isEmpty else { return false }
    let color = appearance.colorHex
    guard color.count == 7 || color.count == 9, color.first == "#" else { return false }
    return color.dropFirst().allSatisfy(\.isHexDigit)
  }
}
