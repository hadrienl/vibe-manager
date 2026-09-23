import Foundation
import VibeDomain

public enum SessionWorkspaceError: Error, Equatable, Sendable, LocalizedError {
  case sessionNotFound
  case sessionArchived
  case repositoryNotFound
  /// Detaching the last repository would leave a session with no place to run.
  case lastRepository

  public var errorDescription: String? {
    switch self {
    case .sessionNotFound: return "This session is no longer in the store."
    case .sessionArchived: return "This session is archived."
    case .repositoryNotFound: return "This repository is no longer attached to the session."
    case .lastRepository: return "A session needs at least one folder."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .sessionNotFound, .repositoryNotFound: return "Reload the workspace."
    case .sessionArchived: return "Unarchive it first."
    case .lastRepository: return "Attach another folder first, then detach this one."
    }
  }
}

/// The command a user can copy to get rid of what a repository left behind.
///
/// The one place a path becomes shell text again, so each one is quoted: a folder called
/// `l'API (v2)` pastes into a terminal as it is. Nothing here is ever run by the application.
public enum RepositoryCleanupCommand {
  public static func make(for repository: RepositoryContext) -> String? {
    guard repository.mode == .worktree, let path = repository.worktreePath else { return nil }
    var lines: [String] = []
    if !repository.createdByVibeManager {
      lines.append("# This worktree existed before the session: make sure nothing else uses it.")
    }
    var command = ShellQuoting.command([
      "git", "-C", repository.rootPath, "worktree", "remove", path,
    ])
    if let branch = repository.branchName, repository.createdByVibeManager {
      command +=
        " && "
        + ShellQuoting.command(["git", "-C", repository.rootPath, "branch", "-d", branch])
    }
    lines.append(command)
    return lines.joined(separator: "\n")
  }
}

/// A repository added to an existing session.
public struct RepositoryAttachment: Sendable {
  public let session: WorkSession
  public let repository: RepositoryContext
  /// What to tell the agent already running, when there is one. Proposed with its text visible,
  /// and sent only on a click: writing into a pseudo terminal is typing on the user's keyboard.
  public let addendum: String?

  public init(session: WorkSession, repository: RepositoryContext, addendum: String?) {
    self.session = session
    self.repository = repository
    self.addendum = addendum
  }
}

/// Adds a repository to a session that already exists, by the same road as creation: read it,
/// plan it, show the plan, prepare it.
public struct AttachRepository: Sendable {
  private let repository: any SessionRepository
  private let services: SessionWorkspaceServices
  private let clock: any SessionClock
  private let conventions = SessionConventionBuilder()

  public init(
    repository: any SessionRepository,
    services: SessionWorkspaceServices,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.services = services
    self.clock = clock
  }

  /// Reads the designated folder once, for the plan to be recomputed from.
  public func inspect(_ candidate: SessionDraftRepository) async -> RepositoryInspection {
    await services.plan.inspect(candidate)
  }

  /// The plan for one more repository, written nowhere.
  public func plan(
    sessionID: SessionID,
    adding candidate: SessionDraftRepository,
    inspection: RepositoryInspection? = nil
  ) async throws -> SessionWorkspacePlan {
    let (session, slug, taken) = try await context(for: sessionID)
    return await services.plan(
      slug: slug,
      repositories: [candidate],
      inspections: inspection.map { [candidate.id: $0] } ?? [:],
      existing: session.repositories,
      takenSlugs: taken,
      sessionFolderPath: session.worktreeFolderPath
    )
  }

  public func callAsFunction(
    sessionID: SessionID,
    adding candidate: SessionDraftRepository,
    isRunning: Bool
  ) async throws -> RepositoryAttachment {
    let (session, slug, taken) = try await context(for: sessionID)
    // Read again, rather than trusting the plan the user looked at: the disk may have moved
    // between the two, and the preparation must meet nothing the plan did not say.
    let plan = await services.plan(
      slug: slug,
      repositories: [candidate],
      existing: session.repositories,
      takenSlugs: taken,
      sessionFolderPath: session.worktreeFolderPath
    )
    let prepared = await services.prepare(plan, attachedAt: clock.now())
    guard let attached = prepared.first else { throw SessionWorkspaceError.repositoryNotFound }

    let updated = try await repository.mutate(id: sessionID) { stored in
      if attached.mode == .worktree { stored.adoptSlugIfMissing(slug) }
      stored.repositories.removeAll { $0.id == attached.id }
      stored.repositories.append(attached)
      try stored.touch(at: max(clock.now(), stored.updatedAt))
    }
    guard let updated else { throw SessionWorkspaceError.sessionNotFound }

    let addendum =
      isRunning && attached.effectivePath != nil
      ? conventions.addendum(for: attached, slug: updated.slug) : nil
    return RepositoryAttachment(session: updated, repository: attached, addendum: addendum)
  }

  /// The session, the slug its worktrees are named with, and the slugs other sessions hold.
  ///
  /// A session stored before worktrees existed has no slug: it is given one from its name the
  /// first time a worktree is attached to it, and keeps it from then on.
  private func context(for id: SessionID) async throws -> (
    WorkSession, SessionSlug, [String: String]
  ) {
    guard let session = try await repository.session(id: id) else {
      throw SessionWorkspaceError.sessionNotFound
    }
    guard session.status != .archived else { throw SessionWorkspaceError.sessionArchived }
    let taken = try await takenSlugs(excluding: id)
    let slug =
      session.slug
      ?? SessionSlug.derived(fromTitle: session.name).firstAvailable {
        taken[$0.rawValue] != nil
      }
    return (session, slug, taken)
  }

  private func takenSlugs(excluding id: SessionID) async throws -> [String: String] {
    try await TakenSessionSlugs(repository: repository)(excluding: id)
  }
}

/// The slugs other sessions are working under, which a new one must not reuse.
///
/// Archived sessions are left out: their branch may be reused on purpose, and the plan says so
/// through the branch that already exists rather than through the session that once had it.
public struct TakenSessionSlugs: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  public func callAsFunction(excluding id: SessionID? = nil) async throws -> [String: String] {
    var taken: [String: String] = [:]
    for session in try await repository.sessions()
    where session.status != .archived && session.id != id {
      if let slug = session.slug { taken[slug.rawValue] = session.name }
    }
    return taken
  }
}

/// A repository taken off a session, and what was left on the disk.
public struct RepositoryDetachment: Sendable {
  public let session: WorkSession
  public let repository: RepositoryContext
  /// The command that would remove what the repository left, to copy. Never run.
  public let cleanupCommand: String?
  /// The main repository was the one detached: the next one is main now, and an agent already
  /// running is still where it was started — a process's working directory cannot be moved.
  public let changedMainRepository: Bool
}

/// Forgets a repository. The worktree, the branch and every file stay exactly where they are.
public struct DetachRepository: Sendable {
  private let repository: any SessionRepository
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.clock = clock
  }

  public func callAsFunction(
    sessionID: SessionID,
    repositoryID: RepositoryID
  ) async throws -> RepositoryDetachment {
    guard let current = try await repository.session(id: sessionID) else {
      throw SessionWorkspaceError.sessionNotFound
    }
    guard let detached = current.repositories.first(where: { $0.id == repositoryID }) else {
      throw SessionWorkspaceError.repositoryNotFound
    }
    guard current.repositories.count > 1 else { throw SessionWorkspaceError.lastRepository }

    let now = clock.now()
    let updated = try await repository.mutate(id: sessionID) { session in
      session.repositories.removeAll { $0.id == repositoryID }
      try session.touch(at: max(now, session.updatedAt))
    }
    guard let updated else { throw SessionWorkspaceError.sessionNotFound }
    return RepositoryDetachment(
      session: updated,
      repository: detached,
      cleanupCommand: RepositoryCleanupCommand.make(for: detached),
      changedMainRepository: current.repositories.first?.id == repositoryID
    )
  }
}

/// Moves a repository to the top of the list, which makes it the main one for the next launch.
public struct MakeMainRepository: Sendable {
  private let repository: any SessionRepository
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.clock = clock
  }

  @discardableResult
  public func callAsFunction(sessionID: SessionID, repositoryID: RepositoryID) async throws
    -> WorkSession
  {
    let now = clock.now()
    let updated = try await repository.mutate(id: sessionID) { session in
      guard let index = session.repositories.firstIndex(where: { $0.id == repositoryID }),
        index > 0
      else { return }
      let moved = session.repositories.remove(at: index)
      session.repositories.insert(moved, at: 0)
      try session.touch(at: max(now, session.updatedAt))
    }
    guard let updated else { throw SessionWorkspaceError.sessionNotFound }
    return updated
  }
}

/// Prepares one repository of a session again: the gesture behind "Recreate the worktree".
///
/// The branch is there already — that is what makes it a session picked up again — so the plan
/// puts the worktree on it, in the folder it had. Whatever stands in the way, a stale record
/// included, is reported with its command, exactly as at creation.
public struct RepairRepository: Sendable {
  private let repository: any SessionRepository
  private let services: SessionWorkspaceServices
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    services: SessionWorkspaceServices,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.services = services
    self.clock = clock
  }

  @discardableResult
  public func callAsFunction(sessionID: SessionID, repositoryID: RepositoryID) async throws
    -> RepositoryContext
  {
    guard let session = try await repository.session(id: sessionID) else {
      throw SessionWorkspaceError.sessionNotFound
    }
    guard session.status != .archived else { throw SessionWorkspaceError.sessionArchived }
    guard let stored = session.repositories.first(where: { $0.id == repositoryID }) else {
      throw SessionWorkspaceError.repositoryNotFound
    }

    let candidate = SessionDraftRepository(
      id: stored.id,
      path: stored.rootPath,
      mode: stored.mode,
      subfolderName: stored.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent },
      choice: stored.mode == .worktree ? .useExistingBranch : nil
    )
    let taken = try await TakenSessionSlugs(repository: repository)(excluding: sessionID)
    let slug =
      session.slug
      ?? SessionSlug.derived(fromTitle: session.name).firstAvailable { taken[$0.rawValue] != nil }
    let plan = await services.plan(
      slug: slug,
      repositories: [candidate],
      existing: session.repositories.filter { $0.id != repositoryID },
      takenSlugs: taken,
      // The worktree it had is its own: finding it where it was is the repair, not a conflict.
      reattaching: [repositoryID],
      sessionFolderPath: session.worktreeFolderPath
    )
    guard let prepared = await services.prepare(plan, attachedAt: clock.now()).first else {
      throw SessionWorkspaceError.repositoryNotFound
    }

    var repaired: RepositoryContext
    if let failure = prepared.failure {
      // A repair that failed changes one thing: the reason. The worktree's path, its base and
      // whose it was are still what the inspector and the cleanup command need.
      repaired = stored
      repaired.failure = failure
    } else {
      repaired = prepared
      repaired.attachedAt = stored.attachedAt ?? prepared.attachedAt
      // What the session has done so far is still measured from where it started.
      repaired.baseline = stored.baseline
      repaired.baseRevision = prepared.baseRevision ?? stored.baseRevision
      if plan.repositories.first?.action == .adoptWorktree {
        // A worktree that was the application's own is still its own once it is back.
        repaired.createdByVibeManager = stored.createdByVibeManager
      }
    }

    let result = repaired

    let now = clock.now()
    let updated = try await repository.mutate(id: sessionID) { session in
      guard let index = session.repositories.firstIndex(where: { $0.id == repositoryID }) else {
        return
      }
      if result.mode == .worktree { session.adoptSlugIfMissing(slug) }
      session.repositories[index] = result
      try session.touch(at: max(now, session.updatedAt))
    }
    guard updated != nil else { throw SessionWorkspaceError.sessionNotFound }
    return result
  }
}
