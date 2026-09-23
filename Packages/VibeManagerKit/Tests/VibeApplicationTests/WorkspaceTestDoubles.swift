import Foundation
import VibeApplication
import VibeDomain

// The doubles the workspace suites share: a Git that answers what a test decides, a writer that
// only writes down what it was asked, and a disk made of a list of missing paths.

/// Where every worktree goes in these suites. Not a real folder: nothing is ever written there.
let workspaceRoot = "/wt"

func slug(_ raw: String) -> SessionSlug {
  SessionSlug.derived(fromTitle: raw)
}

/// The facts of a repository cloned at `root`, on `branch`.
func repositoryFacts(
  _ root: String,
  branch: String? = "main",
  head: String? = "3f2a1c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b",
  dirty: Bool = false,
  submodules: Bool = false,
  defaultBranch: GitBranchReference? = nil,
  branches: Set<String> = ["main"],
  worktrees: [GitWorktreeRecord] = [],
  commonDirectory: String? = nil
) -> GitRepositoryFacts {
  GitRepositoryFacts(
    topLevelPath: root,
    commonDirectory: commonDirectory ?? root + "/.git",
    headRevision: head,
    branchName: branch,
    isDirty: dirty,
    hasSubmodules: submodules,
    defaultBranch: defaultBranch,
    localBranches: branches,
    worktrees: [GitWorktreeRecord(path: root, headRevision: head, branchName: branch)] + worktrees
  )
}

/// A Git that answers from a table, and counts how often it was asked.
actor WorkspaceInspector: RepositoryInspecting {
  private var answers: [String: RepositoryInspection]
  private(set) var calls: [String] = []

  init(_ answers: [String: RepositoryInspection] = [:]) {
    self.answers = answers
  }

  func set(_ path: String, _ inspection: RepositoryInspection) {
    answers[path] = inspection
  }

  func inspect(path: String) async -> RepositoryInspection {
    calls.append(path)
    return answers[path] ?? .unusable(.missing)
  }
}

/// A writer that writes nothing, and fails where it is told to.
///
/// There is no delete in the port it conforms to, so there is nothing to forbid here: what this
/// records is the whole of what the application ever asked the disk for.
actor WorkspaceWriter: WorktreeCreating {
  private(set) var calls: [String] = []
  private(set) var requests: [WorktreeCreationRequest] = []
  private let failingPaths: Set<String>
  private let cancelsOnFirstWorktree: Bool

  init(failingPaths: Set<String> = [], cancelsOnFirstWorktree: Bool = false) {
    self.failingPaths = failingPaths
    self.cancelsOnFirstWorktree = cancelsOnFirstWorktree
  }

  func createSessionFolder(atPath path: String) async throws {
    calls.append("folder \(path)")
  }

  func createWorktree(_ request: WorktreeCreationRequest) async throws {
    calls.append("worktree \(request.worktreePath)")
    requests.append(request)
    if cancelsOnFirstWorktree, requests.count == 1 {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    if failingPaths.contains(request.worktreePath) {
      throw WorktreeCreationError(message: "fatal: refused by the test")
    }
  }

  func createBranchInPlace(repositoryPath: String, commonDirectory: String, branch: String)
    async throws
  {
    calls.append("branch \(repositoryPath) \(branch)")
  }
}

/// A disk where everything exists but what is listed, and anything under the worktree root.
struct WorkspaceFolders: WorkingDirectoryProbe {
  var missing: Set<String> = []

  func inspect(path: String) async -> WorkingDirectoryStatus {
    if missing.contains(path) || path.hasPrefix(workspaceRoot + "/") || path == workspaceRoot {
      return .missing
    }
    return .usable
  }
}

/// A provider that keeps every request it was asked to plan.
actor RequestLog {
  private(set) var requests: [AgentLaunchRequest] = []

  func record(_ request: AgentLaunchRequest) {
    requests.append(request)
  }

  var last: AgentLaunchRequest? { requests.last }
}

struct RecordingProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let log: RequestLog

  init(log: RequestLog = RequestLog(), supportsAdditionalDirectories: Bool = true) {
    descriptor = AgentDescriptor(
      id: AgentProviderID("stub"),
      displayName: "Stub Agent",
      capabilities: AgentCapabilities(
        supportsModelSelection: true,
        supportsInitialPrompt: true,
        supportsResume: true,
        supportsAdditionalDirectories: supportsAdditionalDirectories
      )
    )
    self.log = log
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    await RestorationProvider().availability(forceRefresh: forceRefresh)
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    await log.record(request)
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: request.additionalWorkingDirectoryPaths.flatMap { ["--add-dir", $0] },
      environment: request.additionalEnvironment,
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

struct RecordingRegistry: AgentProviderResolving {
  let provider: RecordingProvider

  func descriptors() async -> [AgentDescriptor] { [provider.descriptor] }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    id == provider.descriptor.id ? provider : nil
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    [provider.descriptor.id: await provider.availability(forceRefresh: forceRefresh)]
  }
}

func workspaceServices(
  inspector: WorkspaceInspector,
  writer: WorkspaceWriter = WorkspaceWriter(),
  folders: WorkspaceFolders = WorkspaceFolders()
) -> SessionWorkspaceServices {
  SessionWorkspaceServices(
    inspector: inspector,
    writer: writer,
    root: FixedWorktreeRoot(path: workspaceRoot),
    folders: folders
  )
}
