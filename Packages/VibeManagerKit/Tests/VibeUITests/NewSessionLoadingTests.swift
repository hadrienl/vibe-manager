import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The New Session sheet's agents and folder come from its model, whatever its view does (#132).
///
/// In the launch of the ticket, every sheet opened without its `.task` ever loading it: "No coding
/// agent was detected on this Mac", no folder proposed, and nothing being looked for, although the
/// launch had detected Claude Code and Codex. Only Detect Again filled the list, sheet by sheet.
@MainActor
@Suite("Opening the New Session sheet loads it", .timeLimit(.minutes(1)))
struct NewSessionLoadingTests {
  private struct NeverReached: Error, CustomStringConvertible {
    let description: String
  }

  /// A state is waited for, not a deadline: the bound only turns a state never reached into a
  /// failure that says which, instead of the suite's time limit.
  private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    while !condition() {
      guard clock.now - start < .seconds(30) else {
        throw NeverReached(description: "Never reached: \(what).")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeModel(
    registry: any AgentProviderResolving, recentFolder: String? = nil
  ) async -> AppModel {
    let repository = WorkspaceRepository(sessions: [])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let folders = recentFolder.map { RecentFolders([RecentFolder(lexicalPath: $0)]) }
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      recentFolderStore: InMemoryRecentFolderStore(folders ?? RecentFolders()))
    await model.load()
    return model
  }

  @Test("With no view to run it, the sheet still lists the agents and proposes the last folder")
  func loadsWithoutItsView() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-new-session-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let model = await makeModel(
      registry: WorkspaceRegistry(providers: [WorkspaceProvider()]), recentFolder: folder)

    model.beginNewSession()
    let sheet = try #require(model.newSessionModel)

    try await waitUntil("the agents listed") { !sheet.agents.isEmpty }
    #expect(sheet.agents.map(\.id.rawValue) == ["stub"])
    #expect(sheet.draft.providerID == "stub")
    try await waitUntil("the last folder proposed") {
      sheet.draft.workingDirectoryPath == folder
    }
  }

  @Test("The sheet's own load joins the one under way instead of detecting a second time")
  func sheetJoinsTheLoad() async throws {
    let registry = CountingRegistry(provider: WorkspaceProvider())
    let model = await makeModel(registry: registry)
    let heldGate = ProbeGate()
    await registry.hold(with: heldGate)
    model.beginNewSession()
    let sheet = try #require(model.newSessionModel)
    try await waitUntil("the detection under way") { sheet.isLoadingAgents }

    // What the sheet's `.task` does once it runs.
    let fromTheView = Task { await sheet.load() }
    await heldGate.open()
    await fromTheView.value

    #expect(sheet.agents.map(\.id.rawValue) == ["stub"])
    #expect(await registry.calls == 1)
  }
}

/// Counts the detections the sheet asks for — the launch asks each provider directly — and can
/// hold them until the test lets them through.
private actor CountingRegistry: AgentProviderResolving {
  let provider: WorkspaceProvider
  private(set) var calls = 0
  private var gate: ProbeGate?

  init(provider: WorkspaceProvider) {
    self.provider = provider
  }

  func hold(with gate: ProbeGate) {
    self.gate = gate
  }

  func descriptors() -> [AgentDescriptor] { [provider.descriptor] }

  func provider(id: AgentProviderID) -> (any AgentProvider)? {
    id == provider.descriptor.id ? provider : nil
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    calls += 1
    await gate?.wait()
    return [provider.descriptor.id: await provider.availability(forceRefresh: forceRefresh)]
  }
}
