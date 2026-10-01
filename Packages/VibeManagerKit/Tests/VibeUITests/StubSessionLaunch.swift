import Foundation
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A session of the stub agent, launched in a folder of its own, and the model that shows it.
@MainActor
struct StubSessionLaunch {
  private static let provider = WorkspaceProvider()

  let model: AppModel
  let session: WorkSession
  let folder: URL

  /// The folder is made here; the caller removes it. `prepare` runs on the model before the
  /// session is launched.
  static func make(
    named name: String, dropStore: (any SessionDropStore)? = nil,
    prepare: (AppModel) -> Void = { _ in }
  ) async throws -> StubSessionLaunch {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: name,
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: folder.path)]
    )
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [provider])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, dropStore: dropStore)
    prepare(model)
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder.path))
    await launcher.launch(session: session, plan: plan)
    await model.load()
    model.select(session.id)
    return StubSessionLaunch(model: model, session: session, folder: folder)
  }
}
