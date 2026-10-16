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

  private func child(
    _ name: String, of coordinator: WorkSession, rank: Int, status: SessionTaskStatus = .todo
  ) -> WorkSession {
    WorkSession(
      name: name, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), taskStatus: status, rank: rank,
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

  @Test("A session coordination is off for is refused every tool, and told to ask the user")
  func coordinationOff() async {
    let model = await makeModel()
    let result = await call(model, "sessions_list", as: alone.id)
    #expect(result.isError)
    #expect(text(result) == CoordinationRefusal.coordinationOff.message)
  }

  @Test("A child is refused every tool: coordination is one level deep")
  func childRefused() async {
    let mine = child("#351", of: parent, rank: 1)
    let model = await makeModel([mine])
    let result = await call(model, "sessions_list", as: mine.id)
    #expect(text(result) == CoordinationRefusal.childCannotCoordinate.message)
  }

  @Test("Any session of an agent that can coordinate turns it on and off; a child cannot")
  func turnedOnAndOff() async throws {
    let ordinary = WorkSession(
      name: "Ordinary", agent: SessionAgentConfiguration(providerID: "claude-code"),
      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 100),
      taskStatus: .doing, rank: 5)
    let mine = WorkSession(
      name: "#351", agent: SessionAgentConfiguration(providerID: "claude-code"),
      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 100),
      taskStatus: .todo, rank: 1,
      coordination: .child(of: parent.id))
    let model = await makeModel([ordinary, mine])
    #expect(model.composerCoordination(for: ordinary.id) == nil)
    model.coordination.coordinatingAgents = ["claude-code"]

    #expect(model.composerCoordination(for: ordinary.id)?.isOn == false)
    #expect(model.composerCoordination(for: mine.id) == nil)
    await model.setCoordinating(true, for: ordinary.id)
    #expect(model.isCoordinator(ordinary.id))
    #expect(!(await call(model, "sessions_list", as: ordinary.id)).isError)
    // Its agent not running, its next launch gives the instructions: nothing is said.
    #expect(model.takeCoordinationNotice(for: ordinary.id) == nil)

    await model.setCoordinating(true, for: mine.id)
    #expect(!model.isCoordinator(mine.id))

    await model.setCoordinating(false, for: ordinary.id)
    #expect(!model.isCoordinator(ordinary.id))
  }

  @Test("Children stay under a coordinator turned off, still folded and summed up")
  func turnedOffKeepsChildren() async throws {
    let mine = child("#351", of: parent, rank: 1)
    let model = await makeModel([mine])
    model.coordination.coordinatingAgents = ["claude-code"]
    await model.setCoordinating(false, for: parent.id)
    let stored = try #require(model.sessions.first { $0.id == parent.id })
    #expect(!model.isCoordinator(parent.id))
    #expect(model.showsAsCoordinator(stored))
    #expect(model.coordinator(of: mine)?.id == parent.id)
  }

  @Test("Turned on while the agent ran, the first answer of a tool gives the rules, once")
  func owedRules() async {
    let model = await makeModel()
    model.coordination.owedRules.insert(parent.id)
    let refused = await call(model, "session_read", ["id": "nothing"], as: parent.id)
    #expect(!text(refused).contains(CoordinatorInstructions.text))
    let first = text(await call(model, "sessions_list", as: parent.id))
    #expect(first.contains(CoordinatorInstructions.text))
    #expect(first.hasSuffix("You have no child session yet."))
    let second = text(await call(model, "sessions_list", as: parent.id))
    #expect(second == "You have no child session yet.")
  }

  @Test("What turning coordination on or off tells the agent goes with the next message, once")
  func notice() async {
    let model = await makeModel()
    model.coordination.notices[parent.id] = true
    #expect(model.takeCoordinationNotice(for: parent.id) == CoordinatorInstructions.turnedOn)
    #expect(model.takeCoordinationNotice(for: parent.id) == nil)
    model.coordination.notices[parent.id] = false
    #expect(model.takeCoordinationNotice(for: parent.id) == CoordinatorInstructions.turnedOff)
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

  @Test("A coordinator's done children wait behind a row that counts them, until it shows them")
  func doneChildrenHidden() async {
    let model = await makeModel([
      child("#351", of: parent, rank: 1), child("#350", of: parent, rank: 2, status: .done),
    ])
    #expect(model.displayedSessions.map(\.name) == ["V2", "#351", "Other", "Alone"])
    #expect(model.doneChildren(ofCoordinator: parent.id) == .init(count: 1, isShown: false))
    let items = SidebarItem.items(of: model.displayedSessions) {
      model.doneChildren(ofCoordinator: $0)
    }
    #expect(items.map(\.id).firstIndex(of: "done-" + parent.id.rawValue.uuidString) == 2)
    model.setShowingDoneChildren(true, coordinator: parent.id)
    #expect(model.displayedSessions.map(\.name) == ["V2", "#351", "#350", "Other", "Alone"])
    #expect(model.doneChildren(ofCoordinator: parent.id)?.isShown == true)
    // Folded, the coordinator has no row of the kind either.
    model.setExpanded(false, coordinator: parent.id)
    #expect(model.doneChildren(ofCoordinator: parent.id) == nil)
  }

  @Test("A coordinator with nothing running is stopped without the question about its children")
  func stopWithoutChildren() async {
    let model = await makeModel([child("#351", of: parent, rank: 1)])
    #expect(!model.asksAboutChildren(of: parent, action: .close))
    #expect(model.pendingCoordinatorStop == nil)
  }

  @Test("Turned off, a coordinator's wake-up and what waited to be told to it go")
  func turnedOffForgetsWakes() async {
    let model = await makeModel()
    _ = await call(model, "wake_after", ["minutes": 15, "reason": "check #351"], as: parent.id)
    model.coordination.inbox.add(.wake("earlier", at: Date()), for: parent.id)
    await model.setCoordinating(false, for: parent.id)
    #expect(model.coordination.wakes[parent.id] == nil)
    #expect(model.coordination.inbox.events(for: parent.id).isEmpty)
    model.coordination.ticker?.cancel()
  }

  @Test("A folder a child is being started in is refused to another, until it runs")
  func folderHeldWhileStarting() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("coordination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = await makeModel()
    model.coordination.startingFolders[CoordinationPolicy.standardized(folder.path)] = "#350"
    let result = await call(
      model, "session_create",
      [
        "name": "#351", "folder": .string(folder.path), "agent": "claude-code",
        "mission": "m",
      ], as: parent.id)
    #expect(result.isError)
    #expect(
      text(result)
        == CoordinationRefusal.folderInUse(path: folder.path, sessionName: "#350").message)
    #expect(model.sessions.count == 3)
  }

  @Test("Something new to tell cuts short the ticker's sleep until a wake-up")
  func tickerWokenEarly() async throws {
    let model = await makeModel()
    _ = await call(model, "wake_after", ["minutes": 15, "reason": "check #351"], as: parent.id)
    while !model.coordination.tickerSleepsLong {
      try await Task.sleep(for: .milliseconds(10))
    }
    // Its coordinator not running, an event is dropped at the next tick: a second, not a minute.
    model.coordination.inbox.add(.wake("now", at: .distantPast), for: parent.id)
    model.startCoordinationTicker()
    let deadline = ContinuousClock.now + .seconds(20)
    while !model.coordination.inbox.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.coordination.inbox.isEmpty)
    model.coordination.ticker?.cancel()
  }

  @Test("The user's message waits for the application's to be typed, then holds the input")
  func userWaitsForApplicationTyping() async {
    let model = await makeModel()
    model.coordination.typing.insert(parent.id)
    let claim = Task { await model.claimTyping(of: parent.id) }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(model.coordination.typing.contains(parent.id))
    model.coordination.typing.remove(parent.id)
    let release = await claim.value
    // Held: the application types nothing into it now.
    #expect(model.coordination.typing.contains(parent.id))
    #expect(!(await model.typeCoordinationMessage("x", into: parent.id)))
    release()
    #expect(!model.coordination.typing.contains(parent.id))
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
