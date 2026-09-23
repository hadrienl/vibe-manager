import Foundation
import VibeDomain

/// What will happen to one repository, decided before anything is written.
public struct RepositoryPlan: Hashable, Sendable, Identifiable {
  public enum Action: Hashable, Sendable {
    /// `git worktree add`, with `-b` when the branch does not exist yet.
    case createWorktree(createsBranch: Bool)
    /// The worktree is already there, on the session's branch: nothing to do.
    case adoptWorktree
    /// The clone itself; `createsBranch` for the one case where the user asked for it.
    case inPlace(createsBranch: Bool)
    case plainFolder
    /// Held back by a conflict. Only this repository: the others go ahead.
    case blocked
  }

  public let id: RepositoryID
  /// The folder the user designated, as they designated it.
  public let designatedPath: String
  /// The clone the repository is attached from: the top of its worktree for a repository, the
  /// designated folder for anything else.
  public let rootPath: String
  public let mode: RepositoryAttachmentMode
  public let action: Action
  public let worktreePath: String?
  public let subfolderName: String?
  public let branchName: String?
  public let baseRevision: String?
  /// "main at 3f2a1c9", "detached HEAD at 3f2a1c9" — what the plan shows as the base.
  public let baseLabel: String?
  public let commonDirectory: String?
  public let createdByVibeManager: Bool
  public let issues: [RepositoryAttachmentIssue]

  public init(
    id: RepositoryID,
    designatedPath: String,
    rootPath: String,
    mode: RepositoryAttachmentMode,
    action: Action,
    worktreePath: String? = nil,
    subfolderName: String? = nil,
    branchName: String? = nil,
    baseRevision: String? = nil,
    baseLabel: String? = nil,
    commonDirectory: String? = nil,
    createdByVibeManager: Bool = false,
    issues: [RepositoryAttachmentIssue] = []
  ) {
    self.id = id
    self.designatedPath = designatedPath
    self.rootPath = rootPath
    self.mode = mode
    self.action = action
    self.worktreePath = worktreePath
    self.subfolderName = subfolderName
    self.branchName = branchName
    self.baseRevision = baseRevision
    self.baseLabel = baseLabel
    self.commonDirectory = commonDirectory
    self.createdByVibeManager = createdByVibeManager
    self.issues = issues.sorted { $0.severity > $1.severity }
  }

  public var isBlocked: Bool { action == .blocked }

  /// A worktree, planned or held back, or a clone given the session's branch.
  public var usesSessionBranch: Bool {
    mode == .worktree || action == .inPlace(createsBranch: true)
  }

  public var blockingIssue: RepositoryAttachmentIssue? {
    issues.first(where: \.isBlocking)
  }

  public var displayName: String {
    let component = URL(fileURLWithPath: rootPath).lastPathComponent
    return component.isEmpty ? rootPath : component
  }

  /// Where the agent will work for this repository.
  public var effectivePath: String? {
    switch action {
    case .createWorktree, .adoptWorktree: return worktreePath
    case .inPlace, .plainFolder: return rootPath
    case .blocked: return nil
    }
  }

  /// The repository this plan leaves attached, whether it was prepared or held back.
  ///
  /// A blocked plan is attached all the same, with the reason it stopped: the session exists, and
  /// the repository is still one gesture away from being prepared.
  public func context(
    attachedAt date: Date,
    failure: RepositoryAttachmentIssue? = nil
  ) -> RepositoryContext {
    let failure = failure ?? blockingIssue
    let prepared = failure == nil && !isBlocked
    return RepositoryContext(
      id: id,
      rootPath: rootPath,
      mode: mode,
      worktreePath: mode == .worktree && prepared ? worktreePath : nil,
      branchName: mode == .plainFolder ? nil : branchName,
      baseRevision: mode == .worktree ? baseRevision : nil,
      createdByVibeManager: prepared && createdByVibeManager,
      attachedAt: date,
      failure: failure?.failure
    )
  }
}

/// Everything a session's preparation will do, shown before it does any of it.
public struct SessionWorkspacePlan: Hashable, Sendable {
  public let slug: SessionSlug?
  public let sessionFolderPath: String?
  public let repositories: [RepositoryPlan]
  /// Problems of the session as a whole — its slug — rather than of one repository.
  public let sessionIssues: [SessionDraftIssue]
  /// The first slug that neither another session nor an attached repository's branches claim.
  public let slugSuggestion: SessionSlug?

  public init(
    slug: SessionSlug?,
    sessionFolderPath: String?,
    repositories: [RepositoryPlan],
    sessionIssues: [SessionDraftIssue] = [],
    slugSuggestion: SessionSlug? = nil
  ) {
    self.slug = slug
    self.sessionFolderPath = sessionFolderPath
    self.repositories = repositories
    self.sessionIssues = sessionIssues
    self.slugSuggestion = slugSuggestion
  }

  public var branchName: String? { slug?.branchName }

  /// Whether any repository is on the session's own branch, which is what makes the slug matter.
  public var usesSessionBranch: Bool {
    repositories.contains(where: \.usesSessionBranch)
  }

  public var createsWorktrees: Bool {
    repositories.contains {
      if case .createWorktree = $0.action { return true }
      return false
    }
  }

  public func plan(for id: RepositoryID) -> RepositoryPlan? {
    repositories.first { $0.id == id }
  }
}

/// Plans a session's repositories from what was read of them. Pure: the same facts give the same
/// plan, which is what lets the sheet recompute it on every keystroke of the slug.
public struct SessionWorkspacePlanner: Sendable {
  public struct Candidate: Hashable, Sendable {
    public let repository: SessionDraftRepository
    public let inspection: RepositoryInspection

    public init(repository: SessionDraftRepository, inspection: RepositoryInspection) {
      self.repository = repository
      self.inspection = inspection
    }
  }

  public struct Input: Sendable {
    public var slug: SessionSlug?
    public var worktreeRootPath: String
    /// Repositories the session already has — for a repository added after creation.
    public var existing: [RepositoryContext]
    public var candidates: [Candidate]
    /// Which of the planned worktree paths already exist on disk, canonical.
    public var occupiedPaths: Set<String>
    /// The slugs of the other sessions still in use, with their names.
    public var takenSlugs: [String: String]
    /// The repositories behind `existing`, canonical, so one attached again through another
    /// folder is recognised.
    public var existingCommonDirectories: Set<String>
    /// Repositories the session already had at this path — a restart, a repair. Only those adopt
    /// the worktree they find there without being asked: at creation, a worktree on the session's
    /// branch belongs to someone else's work until the user says otherwise.
    public var reattaching: Set<RepositoryID>

    public init(
      slug: SessionSlug?,
      worktreeRootPath: String,
      existing: [RepositoryContext] = [],
      candidates: [Candidate],
      occupiedPaths: Set<String> = [],
      takenSlugs: [String: String] = [:],
      existingCommonDirectories: Set<String> = [],
      reattaching: Set<RepositoryID> = []
    ) {
      self.existingCommonDirectories = existingCommonDirectories
      self.reattaching = reattaching
      self.slug = slug
      self.worktreeRootPath = worktreeRootPath
      self.existing = existing
      self.candidates = candidates
      self.occupiedPaths = occupiedPaths
      self.takenSlugs = takenSlugs
    }
  }

  public init() {}

  public func sessionFolderPath(root: String, slug: SessionSlug) -> String {
    (root as NSString).appendingPathComponent(slug.rawValue)
  }

  /// The worktree path each candidate would get, so the caller can look at what is already there
  /// before planning.
  public func targetPaths(for input: Input) -> [RepositoryID: String] {
    guard let slug = input.slug else { return [:] }
    let folder = sessionFolderPath(root: input.worktreeRootPath, slug: slug)
    return subfolderNames(for: input).mapValues { (folder as NSString).appendingPathComponent($0) }
  }

  public func plan(_ input: Input) -> SessionWorkspacePlan {
    let suggestion = input.slug.map { slug in
      slug.firstAvailable { candidate in
        input.takenSlugs[candidate.rawValue] != nil
          || input.candidates.contains { candidateRepository in
            guard case .repository(let facts) = candidateRepository.inspection else {
              return false
            }
            return facts.localBranches.contains(candidate.branchName)
          }
      }
    }

    let names = subfolderNames(for: input)
    let folder = input.slug.map { sessionFolderPath(root: input.worktreeRootPath, slug: $0) }
    var seenCommonDirectories = Set(input.existingCommonDirectories.map(CanonicalPath.of))
    for repository in input.existing where repository.mode == .plainFolder {
      seenCommonDirectories.insert("folder:" + CanonicalPath.of(repository.rootPath))
    }
    var plans: [RepositoryPlan] = []
    for candidate in input.candidates {
      let plan = planRepository(
        candidate,
        input: input,
        subfolderName: names[candidate.repository.id],
        sessionFolder: folder,
        slugSuggestion: suggestion,
        seenCommonDirectories: &seenCommonDirectories
      )
      plans.append(plan)
    }

    // A slug only matters once it names a branch. Two sessions on plain folders, or on clones
    // worked in place, share no branch, whatever their titles.
    var sessionIssues: [SessionDraftIssue] = []
    if plans.contains(where: \.usesSessionBranch), let slug = input.slug,
      let owner = input.takenSlugs[slug.rawValue], let suggestion
    {
      sessionIssues.append(.slugTaken(by: owner, suggestion: suggestion))
    }

    return SessionWorkspacePlan(
      slug: input.slug,
      sessionFolderPath: folder,
      repositories: plans,
      sessionIssues: sessionIssues,
      slugSuggestion: suggestion == input.slug ? nil : suggestion
    )
  }

  // MARK: - One repository

  private func planRepository(
    _ candidate: Candidate,
    input: Input,
    subfolderName: String?,
    sessionFolder: String?,
    slugSuggestion: SessionSlug?,
    seenCommonDirectories: inout Set<String>
  ) -> RepositoryPlan {
    let draft = candidate.repository
    let designated = draft.resolvedPath ?? draft.path

    func blocked(
      _ issue: RepositoryAttachmentIssue,
      mode: RepositoryAttachmentMode,
      root: String = designated,
      extra: [RepositoryAttachmentIssue] = []
    ) -> RepositoryPlan {
      RepositoryPlan(
        id: draft.id,
        designatedPath: designated,
        rootPath: root,
        mode: mode,
        action: .blocked,
        subfolderName: subfolderName,
        issues: [issue] + extra
      )
    }

    guard designated.hasPrefix("/") else {
      return blocked(.notAbsolute, mode: draft.mode ?? .plainFolder)
    }

    let facts: GitRepositoryFacts
    switch candidate.inspection {
    case .unusable(let status):
      return blocked(.folderUnusable(status), mode: draft.mode ?? .plainFolder)
    case .gitUnavailable(let problem):
      return blocked(.gitUnavailable(problem), mode: draft.mode ?? .worktree)
    case .bare(let commonDirectory):
      guard seenCommonDirectories.insert(CanonicalPath.of(commonDirectory)).inserted else {
        return blocked(.duplicate, mode: draft.mode ?? .worktree)
      }
      return blocked(.bare, mode: draft.mode ?? .worktree)
    case .plainFolder:
      let canonical = CanonicalPath.of(designated)
      guard seenCommonDirectories.insert("folder:" + canonical).inserted else {
        return blocked(.duplicate, mode: .plainFolder)
      }
      return RepositoryPlan(
        id: draft.id,
        designatedPath: designated,
        rootPath: designated,
        mode: .plainFolder,
        action: .plainFolder,
        issues: [.notARepository]
      )
    case .repository(let repositoryFacts):
      facts = repositoryFacts
    }

    let common = CanonicalPath.of(facts.commonDirectory)
    let mode = draft.mode == .plainFolder ? .worktree : (draft.mode ?? .worktree)
    guard seenCommonDirectories.insert(common).inserted else {
      return blocked(.duplicate, mode: mode, root: facts.topLevelPath)
    }

    switch mode {
    case .inPlace, .plainFolder:
      return planInPlace(
        draft, facts: facts, designated: designated, slug: input.slug,
        slugSuggestion: slugSuggestion)
    case .worktree:
      return planWorktree(
        draft,
        facts: facts,
        designated: designated,
        input: input,
        subfolderName: subfolderName,
        sessionFolder: sessionFolder,
        slugSuggestion: slugSuggestion
      )
    }
  }

  private func planInPlace(
    _ draft: SessionDraftRepository,
    facts: GitRepositoryFacts,
    designated: String,
    slug: SessionSlug?,
    slugSuggestion: SessionSlug?
  ) -> RepositoryPlan {
    var issues: [RepositoryAttachmentIssue] = []
    if facts.isDirty { issues.append(.dirtyInPlace) }

    var branch = facts.branchName
    var createsBranch = false
    if branch == nil {
      guard draft.choice == .createBranchInPlace, let slug else {
        issues.append(.detachedInPlace)
        return RepositoryPlan(
          id: draft.id, designatedPath: designated, rootPath: facts.topLevelPath,
          mode: .inPlace, action: .blocked, commonDirectory: facts.commonDirectory,
          issues: issues)
      }
      branch = slug.branchName
      createsBranch = true
      if facts.localBranches.contains(slug.branchName) {
        // `switch -c` would refuse; saying it now is the plan's whole job.
        issues.append(
          .branchExistsInPlace(slug.branchName, suggestion: slugSuggestion ?? slug)
        )
        return RepositoryPlan(
          id: draft.id, designatedPath: designated, rootPath: facts.topLevelPath,
          mode: .inPlace, action: .blocked, commonDirectory: facts.commonDirectory,
          issues: issues)
      }
    }

    return RepositoryPlan(
      id: draft.id,
      designatedPath: designated,
      rootPath: facts.topLevelPath,
      mode: .inPlace,
      action: .inPlace(createsBranch: createsBranch),
      branchName: branch,
      commonDirectory: facts.commonDirectory,
      issues: issues
    )
  }

  private func planWorktree(
    _ draft: SessionDraftRepository,
    facts: GitRepositoryFacts,
    designated: String,
    input: Input,
    subfolderName: String?,
    sessionFolder: String?,
    slugSuggestion: SessionSlug?
  ) -> RepositoryPlan {
    let root = facts.topLevelPath

    func blocked(_ issues: [RepositoryAttachmentIssue], path: String? = nil) -> RepositoryPlan {
      RepositoryPlan(
        id: draft.id, designatedPath: designated, rootPath: root, mode: .worktree,
        action: .blocked, worktreePath: path, subfolderName: subfolderName,
        branchName: input.slug?.branchName, commonDirectory: facts.commonDirectory,
        issues: issues)
    }

    guard let slug = input.slug, let sessionFolder else {
      return blocked([.slugNeeded])
    }
    guard let subfolderName, Self.isUsableFolderName(subfolderName) else {
      return blocked([.invalidSubfolder])
    }
    let branch = slug.branchName
    let target = (sessionFolder as NSString).appendingPathComponent(subfolderName)
    let suggestion = slugSuggestion ?? slug

    var notes: [RepositoryAttachmentIssue] = []
    if facts.isDirty { notes.append(.dirtyInWorktree) }
    if facts.hasSubmodules { notes.append(.submodules(worktreePath: target)) }

    // The branch first: where it is checked out decides everything else.
    if let record = facts.worktree(onBranch: branch) {
      let canonicalRecord = CanonicalPath.of(record.path)
      let isTarget = canonicalRecord == CanonicalPath.of(target)
      let adopting =
        draft.choice == .adoptWorktree(path: record.path)
        || (isTarget && input.reattaching.contains(draft.id))
      // Said before any offer to adopt: a worktree whose folder is gone cannot be worked in, and
      // a locked one is somebody's deliberate "leave this alone".
      if record.isPrunable {
        return blocked(
          [.staleWorktree(record, repositoryPath: root, suggestion: suggestion)], path: record.path)
      }
      if record.isLocked {
        return blocked(
          [.lockedWorktree(record, repositoryPath: root, suggestion: suggestion)], path: record.path
        )
      }
      guard adopting else {
        return blocked(
          [.branchCheckedOut(branch, at: record.path, suggestion: suggestion)] + notes,
          path: target)
      }
      // Already where it should be — a preparation run twice, a restart after a crash — or a
      // worktree the user chose to work in. Either way nothing is written.
      return RepositoryPlan(
        id: draft.id,
        designatedPath: designated,
        rootPath: root,
        mode: .worktree,
        action: .adoptWorktree,
        worktreePath: record.path,
        subfolderName: subfolderName,
        branchName: branch,
        commonDirectory: facts.commonDirectory,
        createdByVibeManager: false,
        issues: notes.filter { $0.kind != .submodules && $0.kind != .dirty }
      )
    }

    if let record = facts.worktree(atPath: target) {
      if record.isPrunable {
        return blocked(
          [.staleWorktree(record, repositoryPath: root, suggestion: suggestion)], path: target)
      }
      return blocked(
        [
          .pathOccupied(
            target, slugSuggestion: suggestion,
            subfolderSuggestion: Self.alternativeSubfolder(subfolderName, root: root))
        ], path: target)
    }
    if input.occupiedPaths.contains(CanonicalPath.of(target)) {
      return blocked(
        [
          .pathOccupied(
            target, slugSuggestion: suggestion,
            subfolderSuggestion: Self.alternativeSubfolder(subfolderName, root: root))
        ], path: target)
    }

    let branchExists = facts.localBranches.contains(branch)
    if branchExists, draft.choice != .useExistingBranch {
      return blocked([.branchExists(branch, suggestion: suggestion)] + notes, path: target)
    }

    var base: GitBranchReference?
    var baseLabel: String?
    if !branchExists {
      guard let head = facts.headRevision else { return blocked([.noCommit], path: target) }
      switch draft.base {
      case .head:
        base = GitBranchReference(name: facts.branchName ?? "HEAD", revision: head)
      case .defaultBranch:
        if let defaultBranch = facts.defaultBranch {
          base = defaultBranch
        } else {
          notes.append(.defaultBranchUnknown)
          base = GitBranchReference(name: facts.branchName ?? "HEAD", revision: head)
        }
      }
      if let base {
        let short = String(base.revision.prefix(7))
        baseLabel =
          facts.branchName == nil && draft.base == .head && base.name == "HEAD"
          ? "detached HEAD at \(short)" : "\(base.name) at \(short)"
      }
    } else {
      baseLabel = "the existing \(branch)"
    }

    return RepositoryPlan(
      id: draft.id,
      designatedPath: designated,
      rootPath: root,
      mode: .worktree,
      action: .createWorktree(createsBranch: !branchExists),
      worktreePath: target,
      subfolderName: subfolderName,
      branchName: branch,
      baseRevision: base?.revision,
      baseLabel: baseLabel,
      commonDirectory: facts.commonDirectory,
      createdByVibeManager: true,
      issues: notes
    )
  }

  // MARK: - Folder names

  /// The folder of each candidate under the session's folder.
  ///
  /// The last component of the clone's path; for two of the same name in one session, the parent
  /// component in front (`api`, `legacy-api`), then a counter. A bare counter — `api-2` — would
  /// not say which of the two is which.
  func subfolderNames(for input: Input) -> [RepositoryID: String] {
    var taken = Set(
      input.existing.compactMap { repository -> String? in
        guard let path = repository.worktreePath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
      })
    var names: [RepositoryID: String] = [:]
    for candidate in input.candidates {
      if let chosen = candidate.repository.subfolderName?.trimmingCharacters(in: .whitespaces),
        !chosen.isEmpty
      {
        names[candidate.repository.id] = chosen
        taken.insert(chosen)
        continue
      }
      let root: String
      if case .repository(let facts) = candidate.inspection {
        root = facts.topLevelPath
      } else {
        root = candidate.repository.resolvedPath ?? candidate.repository.path
      }
      let url = URL(fileURLWithPath: root)
      let base = Self.folderName(url.lastPathComponent)
      var name = base
      if taken.contains(name) {
        let parent = Self.folderName(url.deletingLastPathComponent().lastPathComponent)
        name = parent.isEmpty ? base : "\(parent)-\(base)"
        var counter = 2
        let stem = name
        while taken.contains(name) {
          name = "\(stem)-\(counter)"
          counter += 1
        }
      }
      taken.insert(name)
      names[candidate.repository.id] = name
    }
    return names
  }

  private static func folderName(_ component: String) -> String {
    var name = component.replacingOccurrences(of: "/", with: "-")
    while name.hasPrefix(".") { name.removeFirst() }
    return name.isEmpty ? "repository" : name
  }

  static func isUsableFolderName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.utf8.count <= 200
  }

  private static func alternativeSubfolder(_ name: String, root: String) -> String {
    let parent = URL(fileURLWithPath: root).deletingLastPathComponent().lastPathComponent
    let candidate = folderName(parent)
    return candidate.isEmpty || candidate == name ? "\(name)-2" : "\(candidate)-\(name)"
  }
}

extension RepositoryAttachmentIssue {
  static let slugNeeded = RepositoryAttachmentIssue(
    kind: .invalidSubfolder,
    severity: .blocking,
    message: "A worktree needs the session's branch name, and it is not valid yet.",
    remedy: "Fix the branch name above."
  )
}
