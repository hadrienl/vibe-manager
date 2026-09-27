import Foundation
import VibeApplication
import VibeProcess

/// One pass of an agent's CLI outside any session: its own executable and environment — the same
/// account — in a process without a terminal, run from an empty temporary folder that only its
/// owner reads and that is removed afterwards, so that no `CLAUDE.md` or `AGENTS.md` of a project
/// is found. What the journal's summaries (#36) and the avatars (#41) are drawn with.
struct OneShotAgentRun: Sendable {
  /// What to run, given the folder: files the command needs are written there first.
  struct Invocation {
    let arguments: [String]
    let environment: [String: String]
    let input: Data
  }

  enum Failure: Error, Equatable {
    case noWorkspace
    case unavailable(AgentAvailabilityState)
    case noLaunchPlan
    case couldNotStart
  }

  let provider: any AgentProvider
  let runner: any SummaryProcessRunning
  let folderPrefix: String
  let timeout: Duration

  /// Runs the command `prepare` describes, and hands its result to `read` while the folder is
  /// still there. Cancelling the task stops the process.
  func run<Result>(
    prepare: (URL, [AgentModel]) throws -> Invocation,
    read: (BoundedProcessResult, URL) throws -> Result
  ) async throws -> Result {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(folderPrefix)\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw Failure.noWorkspace
    }
    defer { try? FileManager.default.removeItem(at: workspace) }

    let plan: AgentLaunchPlan
    do {
      plan = try await provider.launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: workspace.path))
    } catch AgentLaunchError.unavailable(let state) {
      throw Failure.unavailable(state)
    } catch {
      throw Failure.noLaunchPlan
    }
    let invocation = try prepare(workspace, await provider.models())
    var environment = plan.environment
    environment.merge(invocation.environment) { _, added in added }
    let result: BoundedProcessResult
    do {
      result = try await runner.run(
        BoundedProcessRequest(
          executablePath: plan.executablePath, arguments: invocation.arguments,
          environment: environment, workingDirectoryPath: workspace.path, timeout: timeout,
          standardInput: BoundedProcessInput(data: invocation.input)))
    } catch BoundedProcessError.cancelled {
      throw CancellationError()
    } catch {
      throw Failure.couldNotStart
    }
    return try read(result, workspace)
  }
}
