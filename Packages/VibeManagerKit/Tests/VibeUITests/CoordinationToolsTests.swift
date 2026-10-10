import Foundation
import Testing
import VibeApplication
import VibeBrowser
import VibeDomain

@testable import VibeUI

actor CoordinationRepository: SessionRepository {
  private var stored: [WorkSession]

  init(_ sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }

  func reorder(_ ranks: [SessionID: Int]) {
    for index in stored.indices {
      if let rank = ranks[stored[index].id] { stored[index].rank = rank }
    }
  }
}

private struct OneAgent: AgentProvider {
  let descriptor = AgentDescriptor(
    id: AgentProviderID("claude-code"), displayName: "Claude Code",
    capabilities: AgentCapabilities(
      supportsModelSelection: true, supportsInitialPrompt: true, supportsResume: true))

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available, installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "ready", probedAt: Date(timeIntervalSince1970: 0), remediations: []))
  }

  func models() async -> [AgentModel] {
    [AgentModel(id: "opus", displayName: "Opus", isDefault: true)]
  }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: descriptor.id, executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: request.workingDirectoryPath, promptDelivery: .none)
  }
}

private struct OneAgentRegistry: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [OneAgent().descriptor] }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    id == OneAgent().descriptor.id ? OneAgent() : nil
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    [OneAgent().descriptor.id: await OneAgent().availability(forceRefresh: forceRefresh)]
  }
}

@MainActor
@Suite("A coordinator's tools, on the workspace (#352)")
struct CoordinationToolsTests {
  let parent = WorkSession(
    name: "V2", status: .closed, createdAt: Date(timeIntervalSince1970: 0),
    updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .doing, rank: 0,
    coordination: .coordinator)
  let other = WorkSession(
    name: "Other", createdAt: Date(timeIntervalSince1970: 0),
    updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .doing, rank: 3,
    coordination: .coordinator)
  let alone = WorkSession(
    name: "Alone", createdAt: Date(timeIntervalSince1970: 0),
    updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .doing, rank: 4)

  private func child(_ name: String, of coordinator: WorkSession, rank: Int) -> WorkSession {
    WorkSession(
      name: name, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .todo, rank: rank,
      coordination: .child(of: coordinator.id))
  }

  private func makeModel(_ extra: [WorkSession] = []) async -> AppModel {
    let model = AppModel(
      repository: CoordinationRepository([parent, other, alone] + extra),
      agents: OneAgentRegistry(),
      layout: WorkspaceLayoutController(
        store: RecordingLayoutStore(
          layout: WorkspaceLayout(sessionFilter: SessionFilter(column: .doing, sort: .manual))),
        saveDelay: .zero))
    await model.load()
    return model
  }

  private func call(
    _ model: AppModel, _ tool: String, _ arguments: JSONValue = [:], as caller: SessionID
  ) async -> BrowserToolResult {
    await model.runCoordinationTool(tool, arguments: arguments, caller: caller)
  }

  private func text(_ result: BrowserToolResult) -> String {
    result.content.compactMap {
      if case .text(let text) = $0 { return text }
      return nil
    }.joined()
  }

  @Test("A session that is not a coordinator is refused every tool")
  func notCoordinator() async {
    let model = await makeModel()
    let result = await call(model, "sessions_list", as: alone.id)
    #expect(result.isError)
    #expect(text(result) == CoordinationRefusal.notCoordinator.message)
  }

  @Test("A coordinator lists its own children only, and reads another's as nothing")
  func cloisonnement() async {
    let mine = child("#351", of: parent, rank: 1)
    let theirs = child("#352", of: other, rank: 2)
    let model = await makeModel([mine, theirs])

    let list = text(await call(model, "sessions_list", as: parent.id))
    #expect(list.contains(mine.id.rawValue.uuidString))
    #expect(!list.contains(theirs.id.rawValue.uuidString))

    let foreign = await call(
      model, "session_read", ["id": .string(theirs.id.rawValue.uuidString)], as: parent.id)
    #expect(foreign.isError)
    #expect(
      text(foreign)
        == CoordinationRefusal.unknownChild(theirs.id.rawValue.uuidString).message)
    let send = await call(
      model, "session_send",
      ["id": .string(theirs.id.rawValue.uuidString), "text": "hello"], as: parent.id)
    #expect(send.isError)
  }

  @Test("A child is created under its coordinator, marked, in To Do, and traced")
  func create() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("coordination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = await makeModel()

    let result = await call(
      model, "session_create",
      [
        "name": "#351 Dictation", "folder": .string(folder.path), "agent": "claude-code",
        "mission": "Implement #351.", "start": false,
      ], as: parent.id)

    #expect(!result.isError, "\(text(result))")
    let created = try #require(model.sessions.first { $0.name == "#351 Dictation" })
    #expect(created.coordination == .child(of: parent.id))
    #expect(created.taskStatus == .todo)
    #expect(created.initialPrompt == "[Coordinator “V2”] Implement #351.")
    #expect(model.coordinationTrace(of: created.id).map(\.action) == [.created])
    // Listed under its coordinator, in the coordinator's column, not selected.
    #expect(model.visibleSessions.map(\.name).prefix(2) == ["V2", "#351 Dictation"])
    #expect(model.selectedSessionID != created.id)
  }

  @Test("A folder that does not exist is refused before anything is created")
  func missingFolder() async {
    let model = await makeModel()
    let result = await call(
      model, "session_create",
      ["name": "x", "folder": "/nowhere/at/all", "agent": "claude-code", "mission": "m"],
      as: parent.id)
    #expect(result.isError)
    #expect(model.sessions.count == 3)
  }

  @Test("A child is moved between columns, which the trace says")
  func move() async throws {
    let mine = child("#351", of: parent, rank: 1)
    let model = await makeModel([mine])
    let result = await call(
      model, "session_set_status",
      ["id": .string(mine.id.rawValue.uuidString), "status": "done"], as: parent.id)
    #expect(!result.isError, "\(text(result))")
    #expect(model.sessions.first { $0.id == mine.id }?.taskStatus == .done)
    #expect(model.coordinationTrace(of: mine.id).map(\.action) == [.movedTo(.done)])
    let archived = await call(
      model, "session_set_status",
      ["id": .string(mine.id.rawValue.uuidString), "status": "archived"], as: parent.id)
    #expect(archived.isError)
  }

  @Test("Calling the user marks the coordinator until it is shown")
  func callUser() async {
    let model = await makeModel()
    // On another session: the user is not looking at the coordinator.
    model.select(alone.id)
    let result = await call(model, "notify_user", ["message": "Approve the plan."], as: parent.id)
    #expect(!result.isError)
    #expect(model.isCallingUser(parent.id))
    #expect(model.summary(of: .doing).needsAttention)
    model.coordinationSessionShown(parent.id)
    #expect(!model.isCallingUser(parent.id))
  }

  @Test("A wake-up is kept, within its bounds")
  func wake() async {
    let model = await makeModel()
    let refused = await call(
      model, "wake_after", ["minutes": 0, "reason": "check"], as: parent.id)
    #expect(refused.isError)
    let accepted = await call(
      model, "wake_after", ["minutes": 15, "reason": "check #351"], as: parent.id)
    #expect(!accepted.isError)
    #expect(model.coordination.wakes[parent.id]?.reason == "check #351")
    model.coordination.ticker?.cancel()
  }

  @Test("A folded coordinator hides its children in the sidebar")
  func fold() async {
    let mine = child("#351", of: parent, rank: 1)
    let model = await makeModel([mine])
    #expect(model.visibleSessions.map(\.name) == ["V2", "#351", "Other", "Alone"])
    model.setExpanded(false, coordinator: parent.id)
    #expect(model.displayedSessions.map(\.name) == ["V2", "Other", "Alone"])
    // Still listed: a child on screen keeps the selection when its coordinator folds.
    #expect(model.visibleSessions.map(\.name) == ["V2", "#351", "Other", "Alone"])
    #expect(model.summary(of: .doing).count == 4)
    #expect(model.summary(of: .todo).count == 0)
  }

  @Test("A coordinator with nothing running is stopped without the question about its children")
  func stopWithoutChildren() async {
    let model = await makeModel([child("#351", of: parent, rank: 1)])
    #expect(!model.asksAboutChildren(of: parent, action: .close))
    #expect(model.pendingCoordinatorStop == nil)
  }
}

@MainActor
@Suite("Rearranging coordinators and their children by hand (#352)")
struct CoordinationOrderTests {
  @Test("A coordinator moves among the other sessions with its children; a child among siblings")
  func order() async {
    let first = WorkSession(
      name: "First", createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .doing, rank: 0,
      coordination: .coordinator)
    let childA = WorkSession(
      name: "A", createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .todo, rank: 1,
      coordination: .child(of: first.id))
    let childB = WorkSession(
      name: "B", createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .todo, rank: 2,
      coordination: .child(of: first.id))
    let second = WorkSession(
      name: "Second", createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), taskStatus: .doing, rank: 3)
    let model = AppModel(
      repository: CoordinationRepository([first, childA, childB, second]),
      layout: WorkspaceLayoutController(
        store: RecordingLayoutStore(
          layout: WorkspaceLayout(sessionFilter: SessionFilter(column: .doing, sort: .manual))),
        saveDelay: .zero))
    await model.load()
    #expect(model.visibleSessions.map(\.name) == ["First", "A", "B", "Second"])

    #expect(model.canMove(second.id, by: -1))
    await model.move(second.id, by: -1)
    #expect(model.visibleSessions.map(\.name) == ["Second", "First", "A", "B"])

    #expect(!model.canMove(childA.id, by: -1))
    await model.move(childB.id, by: -1)
    #expect(model.visibleSessions.map(\.name) == ["Second", "First", "B", "A"])
  }
}
