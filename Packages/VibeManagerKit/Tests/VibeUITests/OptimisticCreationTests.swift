import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Creating a session without waiting for it", .timeLimit(.minutes(2)))
struct OptimisticCreationTests {
  private let folder = FileManager.default.temporaryDirectory.path

  private func existing() -> WorkSession {
    SessionDraft(name: "Existing", providerID: "stub", workingDirectoryPath: folder).session()
  }

  private func makeModel(_ repository: GatedRepository) async -> AppModel {
    let launcher = SessionLauncher(
      supervisor: FakeSupervisor(), repository: repository, agents: OneAgent(),
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: OneAgent(), launcher: launcher)
    await model.load()
    return model
  }

  private func openSheet(in model: AppModel, name: String, folder: String) throws
    -> NewSessionModel
  {
    model.beginNewSession()
    let sheet = try #require(model.newSessionModel)
    sheet.draft = SessionDraft(name: name, providerID: "stub", workingDirectoryPath: folder)
    return sheet
  }

  /// A state is waited for, not a deadline: a CI runner whose cooperative pool is saturated can
  /// leave the creation unscheduled for seconds. The bound only stops a state never reached, which
  /// the `#expect` around the call then names.
  private func settled(_ model: AppModel) async -> Bool {
    await eventually { model.sessionInCreation == nil }
  }

  private func eventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    while !condition() {
      guard clock.now - start < .seconds(60) else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  @Test("Create closes the sheet and shows the session to come before it is even stored")
  func placeholderComesFirst() async throws {
    let previous = existing()
    let repository = GatedRepository(sessions: [previous])
    let model = await makeModel(repository)
    model.select(previous.id)
    _ = try openSheet(in: model, name: "Brand new", folder: folder)

    model.submitNewSession(launching: true)

    #expect(!model.isPresentingNewSession)
    #expect(model.shownCreation?.name == "Brand new")
    #expect(model.shownCreation?.phase == .saving)
    #expect(model.creationRow?.name == "Brand new")

    await repository.open()
    #expect(await settled(model))
    let created = try #require(model.sessions.first { $0.name == "Brand new" })
    #expect(model.selectedSessionID == created.id)
    #expect(model.pane(for: created.id) != nil)
    #expect(model.shownCreation == nil)
    #expect(model.creationRow == nil)
  }

  @Test("A draft refused after the sheet closed brings the sheet back, with its problems")
  func refusalReopensTheSheet() async throws {
    let previous = existing()
    let repository = GatedRepository(sessions: [previous], open: true)
    let model = await makeModel(repository)
    model.select(previous.id)
    let sheet = try openSheet(in: model, name: "Nowhere", folder: "/nonexistent/\(UUID())")

    model.submitNewSession(launching: true)
    #expect(await settled(model))

    #expect(model.isPresentingNewSession)
    #expect(model.newSessionModel === sheet)
    #expect(sheet.draft.name == "Nowhere")
    #expect(sheet.issues.contains(.workingDirectoryNotFound))
    #expect(model.sessions.map(\.id) == [previous.id])
    #expect(model.selectedSessionID == previous.id)
  }

  @Test("A session selected while the new one is made stays on screen when it is ready")
  func goingElsewhereIsKept() async throws {
    let first = existing()
    let second = existing()
    let repository = GatedRepository(sessions: [first, second])
    let model = await makeModel(repository)
    model.select(first.id)
    _ = try openSheet(in: model, name: "Later", folder: folder)

    model.submitNewSession(launching: true)
    // A row the sidebar shows: sessions that never ran are in To Do.
    model.setColumn(.todo)
    model.select(second.id)

    #expect(model.shownCreation == nil)
    // Still in the sidebar: it is being made, whatever is on screen.
    #expect(model.creationRow?.name == "Later")

    await repository.open()
    #expect(await settled(model))
    #expect(model.sessions.contains { $0.name == "Later" })
    #expect(model.selectedSessionID == second.id)
  }

  @Test("A second Create while the first is on its way waits in its sheet, and leaves it alone")
  func secondCreationWaitsInItsSheet() async throws {
    let repository = GatedRepository(sessions: [])
    let model = await makeModel(repository)
    _ = try openSheet(in: model, name: "First", folder: folder)
    model.submitNewSession(launching: true)
    _ = try openSheet(in: model, name: "Second", folder: folder)

    model.submitNewSession(launching: true)

    #expect(model.isPresentingNewSession)
    #expect(model.sessionInCreation?.name == "First")

    await repository.open()
    #expect(await settled(model))
    _ = await eventually { model.sessions.count >= 2 }
    #expect(Set(model.sessions.map(\.name)) == ["First", "Second"])
    #expect(!model.isPresentingNewSession)
  }

  @Test("A draft that fails its own checks keeps the sheet open")
  func localProblemsStayInTheSheet() async throws {
    let repository = GatedRepository(sessions: [], open: true)
    let model = await makeModel(repository)
    let sheet = try openSheet(in: model, name: "   ", folder: folder)

    #expect(await sheet.refusesBeforeCreating())
    #expect(!sheet.issues.isEmpty)
    #expect(model.isPresentingNewSession)
    #expect(model.sessionInCreation == nil)
  }
}

/// Holds every write until it is opened, so what the window shows meanwhile can be looked at.
private actor GatedRepository: SessionRepository {
  private var stored: [WorkSession]
  private var isOpen: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(sessions: [WorkSession], open: Bool = false) {
    stored = sessions
    isOpen = open
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) async {
    if !isOpen {
      await withCheckedContinuation { waiters.append($0) }
    }
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private struct OneAgent: AgentProviderResolving, AgentProvider {
  var descriptor: AgentDescriptor {
    AgentDescriptor(
      id: AgentProviderID("stub"), displayName: "Stub",
      capabilities: AgentCapabilities(
        supportsModelSelection: false, supportsInitialPrompt: true, supportsResume: false))
  }

  func descriptors() async -> [AgentDescriptor] { [descriptor] }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    id == descriptor.id ? self : nil
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    [descriptor.id: await availability(forceRefresh: forceRefresh)]
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "Ready.", probedAt: Date(timeIntervalSince1970: 0), remediations: []))
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: descriptor.id, executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: request.workingDirectoryPath, promptDelivery: .none)
  }
}

private actor FakeSupervisor: TerminalSupervisor {
  private var sessions: [TerminalID: FakeTerminal] = [:]

  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    let session = FakeTerminal(id: id)
    sessions[id] = session
    return session
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: TerminalID, gracePeriod: Duration) {}

  func stopAll(gracePeriod: Duration) {}
}

private actor FakeTerminal: TerminalSession {
  nonisolated let id: TerminalID

  init(id: TerminalID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    TerminalAttachment(
      state: .running(processIdentifier: 4242),
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: AsyncStream { $0.finish() })
  }

  func state() -> TerminalProcessState { .running(processIdentifier: 4242) }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {}

  func kill() {}
}
