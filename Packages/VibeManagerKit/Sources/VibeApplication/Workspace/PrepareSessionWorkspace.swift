import Foundation
import VibeDomain

/// Everything the workspace side of a session needs, in one value handed to the use cases.
///
/// Absent in a workspace assembled without Git — the tests of #7, a preview — where every folder
/// is attached in place, exactly as it was before worktrees existed.
public struct SessionWorkspaceServices: Sendable {
  public let inspector: any RepositoryInspecting
  public let writer: any WorktreeCreating
  public let root: any WorktreeRootProviding
  public let folders: any WorkingDirectoryProbe
  /// Reads the branches for the session report. Absent, no report is made.
  public let activity: (any RepositoryActivityReading)?
  /// Reads the agents' transcripts, which is how the report knows where each session worked.
  public let transcripts: (any SessionTranscriptReading)?

  public init(
    inspector: any RepositoryInspecting,
    writer: any WorktreeCreating,
    root: any WorktreeRootProviding,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    activity: (any RepositoryActivityReading)? = nil,
    transcripts: (any SessionTranscriptReading)? = nil
  ) {
    self.transcripts = transcripts
    self.inspector = inspector
    self.writer = writer
    self.root = root
    self.folders = folders
    self.activity = activity
  }

  public var plan: PlanSessionWorkspace {
    PlanSessionWorkspace(inspector: inspector, folders: folders, root: root)
  }

  public var prepare: PrepareSessionWorkspace {
    PrepareSessionWorkspace(writer: writer)
  }
}

/// Reads the repositories of a session to be, and plans them. Writes nothing.
public struct PlanSessionWorkspace: Sendable {
  private let inspector: any RepositoryInspecting
  private let folders: any WorkingDirectoryProbe
  private let root: any WorktreeRootProviding
  private let planner = SessionWorkspacePlanner()

  public init(
    inspector: any RepositoryInspecting,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    root: any WorktreeRootProviding
  ) {
    self.inspector = inspector
    self.folders = folders
    self.root = root
  }

  public func inspect(_ repository: SessionDraftRepository) async -> RepositoryInspection {
    guard let path = repository.resolvedPath, path.hasPrefix("/") else {
      return .unusable(.missing)
    }
    return await inspector.inspect(path: path)
  }

  /// - Parameters:
  ///   - inspections: what was already read of these folders. A repository missing from it is
  ///     read now — so passing none reads everything, which is what creation does.
  ///   - existing: the repositories a session already has, when one is added to it.
  ///   - takenSlugs: the slugs of the other sessions still in use, by name.
  public func callAsFunction(
    slug: SessionSlug?,
    repositories: [SessionDraftRepository],
    inspections known: [RepositoryID: RepositoryInspection] = [:],
    existing: [RepositoryContext] = [],
    takenSlugs: [String: String] = [:],
    reattaching: Set<RepositoryID> = [],
    sessionFolderPath: String? = nil
  ) async -> SessionWorkspacePlan {
    var candidates: [SessionWorkspacePlanner.Candidate] = []
    for repository in repositories {
      let inspection: RepositoryInspection
      if let known = known[repository.id] {
        inspection = known
      } else {
        inspection = await inspect(repository)
      }
      candidates.append(.init(repository: repository, inspection: inspection))
    }

    var existingCommonDirectories: Set<String> = []
    for repository in existing where repository.mode != .plainFolder {
      if case .repository(let facts) = await inspector.inspect(path: repository.rootPath) {
        existingCommonDirectories.insert(facts.commonDirectory)
      }
    }

    // A session that already has a folder keeps it, even if the root moved in the settings since:
    // one session spread over two folders is exactly what a single root was meant to avoid.
    let rootPath: String
    if let sessionFolderPath {
      rootPath = (sessionFolderPath as NSString).deletingLastPathComponent
    } else {
      rootPath = await root.worktreeRootPath()
    }
    var input = SessionWorkspacePlanner.Input(
      slug: slug,
      worktreeRootPath: rootPath,
      existing: existing,
      candidates: candidates,
      takenSlugs: takenSlugs,
      existingCommonDirectories: existingCommonDirectories,
      reattaching: reattaching
    )
    // What is already on the disk where a worktree would go, looked at before the plan is shown:
    // a preparation that meets an obstacle it did not announce is a bug, not an edge case.
    for (_, path) in planner.targetPaths(for: input)
    where await folders.inspect(path: path) != .missing {
      input.occupiedPaths.insert(CanonicalPath.of(path))
    }
    return planner.plan(input)
  }
}

/// Where a preparation has got to, as it goes.
public enum WorkspacePreparationProgress: Hashable, Sendable {
  case started(repositoryName: String, index: Int, total: Int)
  case finished(RepositoryContext)
}

/// Carries out a plan, one repository after the other, each one alone.
///
/// A queue of independent repositories: the one that refuses is attached with what it said, and
/// the others are prepared anyway. What succeeded is kept when something later fails — undoing it
/// "cleanly" would destroy work nobody asked to lose, which is the one thing this never does.
public struct PrepareSessionWorkspace: Sendable {
  private let writer: any WorktreeCreating

  public init(writer: any WorktreeCreating) {
    self.writer = writer
  }

  public func callAsFunction(
    _ plan: SessionWorkspacePlan,
    attachedAt date: Date,
    onProgress: @Sendable (WorkspacePreparationProgress) async -> Void = { _ in
      // A caller that only wants the result watches nothing as it lands.
    }
  ) async -> [RepositoryContext] {
    var prepared: [RepositoryContext] = []
    var folderFailure: RepositoryAttachmentIssue?
    var folderCreated = false
    let total = plan.repositories.count

    for (index, repository) in plan.repositories.enumerated() {
      // Honoured between two repositories only: a worktree half written is worse than one more
      // worktree, which a repair then adopts.
      if Task.isCancelled {
        let context = repository.context(attachedAt: date, failure: .cancelled)
        prepared.append(context)
        await onProgress(.finished(context))
        continue
      }
      await onProgress(
        .started(repositoryName: repository.displayName, index: index + 1, total: total))

      var failure: RepositoryAttachmentIssue?
      switch repository.action {
      case .blocked, .plainFolder, .adoptWorktree, .inPlace(createsBranch: false):
        break
      case .inPlace(createsBranch: true):
        failure = await attempt {
          try await writer.createBranchInPlace(
            repositoryPath: repository.rootPath,
            commonDirectory: repository.commonDirectory ?? repository.rootPath,
            branch: repository.branchName ?? ""
          )
        }
      case .createWorktree(let createsBranch):
        if !folderCreated, folderFailure == nil, let folder = plan.sessionFolderPath {
          folderFailure = await attempt { try await writer.createSessionFolder(atPath: folder) }
          folderCreated = folderFailure == nil
        }
        if let folderFailure {
          failure = folderFailure
        } else if let path = repository.worktreePath, let branch = repository.branchName {
          failure = await attempt {
            try await writer.createWorktree(
              WorktreeCreationRequest(
                repositoryPath: repository.rootPath,
                commonDirectory: repository.commonDirectory ?? repository.rootPath,
                worktreePath: path,
                branchName: branch,
                createsBranch: createsBranch,
                baseRevision: repository.baseRevision
              )
            )
          }
        }
      }

      let context = repository.context(attachedAt: date, failure: failure)
      prepared.append(context)
      await onProgress(.finished(context))
    }
    return prepared
  }

  private func attempt(_ write: () async throws -> Void) async -> RepositoryAttachmentIssue? {
    do {
      try await write()
      return nil
    } catch let error as WorktreeCreationError {
      return .preparationFailed(error.message)
    } catch let error as GitUnavailable {
      return .gitUnavailable(error)
    } catch {
      return .preparationFailed(error.localizedDescription)
    }
  }
}

/// What a repository of a stored session turned out to be, just before a launch.
public enum RepositoryVerification: Hashable, Sendable {
  case ready
  /// The worktree is there, on another branch than the one recorded. Possibly deliberate, so the
  /// session starts as it is, and says so.
  case otherBranch(expected: String, actual: String?)
  case worktreeMissing(path: String)
  case cloneMissing(path: String)
  /// It was never prepared, and still carries why.
  case notPrepared(RepositoryPreparationFailure)

  public var isUsable: Bool {
    switch self {
    case .ready, .otherBranch: return true
    case .worktreeMissing, .cloneMissing, .notPrepared: return false
    }
  }

  public func sentence(for repository: RepositoryContext) -> String? {
    switch self {
    case .ready:
      return nil
    case .otherBranch(let expected, let actual):
      let shown = actual ?? "a detached HEAD"
      return "\(repository.displayName) is on \(shown), not \(expected)."
    case .worktreeMissing(let path):
      return "The worktree of \(repository.displayName), \(path), no longer exists."
    case .cloneMissing(let path):
      return "\(repository.displayName) is no longer at \(path)."
    case .notPrepared(let failure):
      return "\(repository.displayName) was never prepared: \(failure.message)"
    }
  }
}

/// Reads every repository of a session again before it is launched, and repairs nothing.
///
/// Restarting (#10) and restoring (#11) go through it. A worktree that is where it should be costs
/// one folder check; the rest is said, never fixed behind the user's back.
public struct VerifySessionWorkspace: Sendable {
  private let folders: any WorkingDirectoryProbe
  private let inspector: (any RepositoryInspecting)?

  public init(
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    inspector: (any RepositoryInspecting)? = nil
  ) {
    self.folders = folders
    self.inspector = inspector
  }

  public func callAsFunction(_ session: WorkSession) async -> [RepositoryID: RepositoryVerification]
  {
    var verdicts: [RepositoryID: RepositoryVerification] = [:]
    for repository in session.repositories {
      verdicts[repository.id] = await verify(repository)
    }
    return verdicts
  }

  public func verify(_ repository: RepositoryContext) async -> RepositoryVerification {
    if let failure = repository.failure { return .notPrepared(failure) }
    switch repository.mode {
    case .plainFolder, .inPlace:
      return await folders.inspect(path: repository.rootPath) == .usable
        ? .ready : .cloneMissing(path: repository.rootPath)
    case .worktree:
      guard let path = repository.worktreePath else {
        return .notPrepared(
          RepositoryPreparationFailure(
            message: "No worktree was recorded.", remedy: "Recreate the worktree."))
      }
      guard await folders.inspect(path: repository.rootPath) == .usable else {
        return .cloneMissing(path: repository.rootPath)
      }
      guard await folders.inspect(path: path) == .usable else {
        return .worktreeMissing(path: path)
      }
      guard let inspector, let expected = repository.branchName,
        case .repository(let facts) = await inspector.inspect(path: path)
      else {
        return .ready
      }
      return facts.branchName == expected
        ? .ready : .otherBranch(expected: expected, actual: facts.branchName)
    }
  }
}
