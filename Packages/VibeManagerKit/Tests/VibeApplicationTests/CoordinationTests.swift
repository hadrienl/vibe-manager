import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private func session(
  _ name: String, id: SessionID = SessionID(), status: SessionStatus = .closed,
  task: SessionTaskStatus? = nil, folder: String? = nil, rank: Int = 0,
  coordination: SessionCoordination? = nil
) -> WorkSession {
  WorkSession(
    id: id, name: name, initialPrompt: "prompt of \(name)", status: status,
    createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 100),
    archivedAt: status == .archived ? Date(timeIntervalSince1970: 50) : nil,
    startedAt: status == .closed ? nil : Date(timeIntervalSince1970: 10),
    repositories: folder.map { [RepositoryContext(path: $0)] } ?? [],
    taskStatus: task, rank: rank, coordination: coordination, infersStartedAt: false)
}

@Suite("What a coordinator may do to which session")
struct CoordinationPolicyTests {
  let parentID: SessionID
  let sessions: [WorkSession]

  init() {
    let parentID = SessionID()
    let otherID = SessionID()
    self.parentID = parentID
    sessions = [
      session("V2", id: parentID, coordination: .coordinator),
      session("Other", id: otherID, coordination: .coordinator),
      session("#351", coordination: .child(of: parentID)),
      session("#352", coordination: .child(of: otherID)),
      session("Alone"),
    ]
  }

  @Test("Only a coordinator has children")
  func onlyCoordinators() throws {
    let alone = try #require(sessions.first { $0.name == "Alone" })
    #expect(throws: CoordinationRefusal.notCoordinator) {
      try CoordinationPolicy.coordinator(alone.id, among: sessions)
    }
    #expect(try CoordinationPolicy.coordinator(parentID, among: sessions).name == "V2")
  }

  @Test("Another coordinator's child, or an ordinary session, reads as an id that names nothing")
  func foreignChildIsUnknown() throws {
    let foreign = try #require(sessions.first { $0.name == "#352" })
    let alone = try #require(sessions.first { $0.name == "Alone" })
    let missing = UUID().uuidString
    for text in [foreign.id.rawValue.uuidString, alone.id.rawValue.uuidString, missing] {
      #expect(throws: CoordinationRefusal.unknownChild(text)) {
        try CoordinationPolicy.child(text, of: parentID, among: sessions)
      }
    }
    let own = try #require(sessions.first { $0.name == "#351" })
    #expect(
      try CoordinationPolicy.child(own.id.rawValue.uuidString, of: parentID, among: sessions).id
        == own.id)
  }

  @Test("An archived child is no longer one of the coordinator's")
  func archivedChildIsGone() {
    let archived = session("Old", status: .archived, coordination: .child(of: parentID))
    #expect(
      CoordinationPolicy.children(of: parentID, among: sessions + [archived]).map(\.name)
        == ["#351"])
  }

  @Test("No more children run than the limit, and the limit is at least one")
  func limit() throws {
    try CoordinationPolicy.checkLimit(running: 2, limit: 3)
    #expect(throws: CoordinationRefusal.limitReached(running: 3, limit: 3)) {
      try CoordinationPolicy.checkLimit(running: 3, limit: 3)
    }
    #expect(throws: CoordinationRefusal.limitReached(running: 1, limit: 1)) {
      try CoordinationPolicy.checkLimit(running: 1, limit: 0)
    }
  }

  @Test("Two running sessions never share a folder, however it is written")
  func folders() throws {
    let running = session("Busy", status: .active, task: .doing, folder: "/tmp/work/")
    let idle = session("Idle", folder: "/tmp/other")
    #expect(throws: CoordinationRefusal.folderInUse(path: "/tmp/work", sessionName: "Busy")) {
      try CoordinationPolicy.checkFolder("/tmp/work", among: [running, idle]) {
        $0 == running.id
      }
    }
    try CoordinationPolicy.checkFolder("/tmp/other", among: [running, idle]) { $0 == running.id }
  }

  @Test("A child waiting for the user, showing a panel or stopped is never typed into")
  func sending() throws {
    let child = session("#351", coordination: .child(of: parentID))
    #expect(throws: CoordinationRefusal.childAwaitingUser("#351")) {
      try CoordinationPolicy.checkSend(
        to: child, isRunning: true, activity: .awaitingUser(.approval), showsPanel: false)
    }
    #expect(throws: CoordinationRefusal.childAwaitingUser("#351")) {
      try CoordinationPolicy.checkSend(
        to: child, isRunning: true, activity: .awaitingUser(.question), showsPanel: false)
    }
    #expect(throws: CoordinationRefusal.childShowingPanel("#351")) {
      try CoordinationPolicy.checkSend(
        to: child, isRunning: true, activity: .idle, showsPanel: true)
    }
    #expect(throws: CoordinationRefusal.childNotRunning("#351")) {
      try CoordinationPolicy.checkSend(
        to: child, isRunning: false, activity: nil, showsPanel: false)
    }
    try CoordinationPolicy.checkSend(
      to: child, isRunning: true, activity: .working, showsPanel: false)
  }

  @Test("A coordinator's message is marked as its own")
  func marked() {
    #expect(
      CoordinationPolicy.fromCoordinator("  Rebase on main.\n", coordinatorName: "V2")
        == "[Coordinator “V2”] Rebase on main.")
  }
}

@Suite("What waits to be told to a coordinator")
struct CoordinationInboxTests {
  let coordinator = SessionID()
  let child = SessionID()

  func event(_ kind: CoordinationEvent.Kind, at seconds: TimeInterval) -> CoordinationEvent {
    CoordinationEvent(
      childID: child, childName: "#351", kind: kind, date: Date(timeIntervalSince1970: seconds))
  }

  @Test("Events are told once the burst is over, together")
  func quietPeriod() {
    var inbox = CoordinationInbox()
    inbox.add(event(.turnEnded, at: 0), for: coordinator)
    inbox.add(event(.awaitingUser("permission to use Bash: rm -rf build"), at: 2), for: coordinator)
    #expect(inbox.due(at: Date(timeIntervalSince1970: 4)).isEmpty)
    #expect(inbox.due(at: Date(timeIntervalSince1970: 5)) == [coordinator])
    let events = inbox.take(for: coordinator)
    #expect(events.count == 2)
    #expect(inbox.isEmpty)
    let message = CoordinationInbox.message(for: events)
    #expect(message.hasPrefix("[Vibe Manager] 2 events:"))
    #expect(message.contains("finished its turn"))
    #expect(message.contains("is waiting for the user: permission to use Bash: rm -rf build"))
    #expect(message.contains(child.rawValue.uuidString))
  }

  @Test("The same news about the same child is told once")
  func repeatsCollapse() {
    var inbox = CoordinationInbox()
    inbox.add(event(.turnEnded, at: 0), for: coordinator)
    inbox.add(event(.turnEnded, at: 1), for: coordinator)
    #expect(inbox.events(for: coordinator).count == 1)
    #expect(inbox.events(for: coordinator).first?.date == Date(timeIntervalSince1970: 1))
  }

  @Test("A new wake-up replaces the one still waiting")
  func wakeReplaced() {
    var inbox = CoordinationInbox()
    inbox.add(.wake("check #351", at: Date(timeIntervalSince1970: 0)), for: coordinator)
    inbox.add(.wake("check #352", at: Date(timeIntervalSince1970: 1)), for: coordinator)
    #expect(inbox.events(for: coordinator).map(\.kind) == [.wake("check #352")])
  }

  @Test("A long burst is cut, and says how many were left out")
  func cut() {
    let events = (0..<25).map { _ in
      CoordinationEvent(childID: SessionID(), childName: "c", kind: .stopped, date: Date())
    }
    let message = CoordinationInbox.message(for: events)
    #expect(message.contains("and 5 more"))
  }

  @Test("A dropped coordinator is told nothing")
  func dropped() {
    var inbox = CoordinationInbox()
    inbox.add(event(.stopped, at: 0), for: coordinator)
    inbox.drop(coordinator)
    #expect(inbox.isEmpty)
  }
}

@Suite("Coordinators and their children in the sidebar")
struct SessionHierarchyTests {
  let parentID = SessionID()

  @Test("Each child follows its coordinator, in the coordinator's column, whatever its own")
  func childrenUnderParent() {
    let parent = session("V2", id: parentID, task: .doing, rank: 2, coordination: .coordinator)
    let done = session("#351", task: .done, rank: 0, coordination: .child(of: parentID))
    let todo = session("#352", task: .todo, rank: 1, coordination: .child(of: parentID))
    let alone = session("Alone", task: .doing, rank: 3)
    let sessions = [done, todo, parent, alone]
    let filter = SessionFilter(column: .doing, sort: .manual)

    #expect(
      SessionHierarchy.apply(filter, to: sessions).map(\.name) == ["V2", "#351", "#352", "Alone"])
    #expect(SessionHierarchy.apply(SessionFilter(column: .done), to: sessions).isEmpty)
    #expect(SessionHierarchy.apply(SessionFilter(column: .todo), to: sessions).isEmpty)
    let byID = SessionHierarchy.index(sessions)
    #expect(SessionHierarchy.column(of: done, in: byID) == .doing)
  }

  @Test("A folded coordinator hides its children, unless a search looks for them")
  func folded() {
    let parent = session("V2", id: parentID, task: .doing, coordination: .coordinator)
    let child = session("Dictation", task: .doing, coordination: .child(of: parentID))
    var filter = SessionFilter(column: .doing)
    #expect(
      SessionHierarchy.apply(filter, to: [parent, child], collapsed: [parentID]).map(\.name)
        == ["V2"])
    filter.searchText = "dictation"
    #expect(
      SessionHierarchy.apply(filter, to: [parent, child], collapsed: [parentID]).map(\.name)
        == ["V2", "Dictation"])
  }

  @Test("A search that finds a child shows its coordinator, and only the children found")
  func search() {
    let parent = session("V2", id: parentID, task: .doing, coordination: .coordinator)
    let found = session("Dictation", task: .doing, coordination: .child(of: parentID))
    let other = session("Guide", task: .doing, coordination: .child(of: parentID))
    var filter = SessionFilter(column: .doing)
    filter.searchText = "dicta"
    #expect(
      SessionHierarchy.apply(filter, to: [parent, found, other]).map(\.name) == ["V2", "Dictation"])
    filter.searchText = "V2"
    #expect(
      SessionHierarchy.apply(filter, to: [parent, found, other]).map(\.name).count == 3)
  }

  @Test("A child whose coordinator is archived or gone is an ordinary session in its own column")
  func orphan() {
    let archived = session("V2", id: parentID, status: .archived, coordination: .coordinator)
    let child = session("#351", task: .done, coordination: .child(of: parentID))
    let lost = session("#352", task: .done, coordination: .child(of: SessionID()))
    #expect(
      SessionHierarchy.apply(SessionFilter(column: .done), to: [archived, child, lost]).map(\.name)
        .sorted() == ["#351", "#352"])
  }
}

@Suite("What a coordinator reads of its children")
struct CoordinationDigestTests {
  private func request(_ content: AgentRequestContent) -> AgentRequest {
    AgentRequest(
      id: AgentRequestID(sessionID: SessionID(), key: "1"), receivedAt: Date(),
      kind: .approval, content: content, reference: AgentToolReference(tool: "Bash"), isShown: true)
  }

  @Test("A permission says the tool and what it would run, its control characters named")
  func permission() {
    let summary = CoordinationDigest.summary(
      of: request(
        .permission(
          AgentToolPermission(
            tool: .shell, toolName: "Bash", subject: "rm -rf build\u{1B}[2J", purpose: nil,
            details: nil))))
    #expect(summary.hasPrefix("permission to use Bash: rm -rf build"))
    #expect(!summary.contains("\u{1B}"))
  }

  @Test("The last entries are kept, within the limit, in their order")
  func transcript() {
    let entries = (0..<30).map {
      ConversationEntry(id: "\($0)", content: .agentText("answer \($0)"))
    }
    let text = CoordinationDigest.transcript(entries, last: 3)
    #expect(text == "Agent: answer 27\n\nAgent: answer 28\n\nAgent: answer 29")
    let bounded = CoordinationDigest.transcript(entries, last: 100, limit: 40)
    #expect(bounded.count <= 40)
    #expect(bounded.hasSuffix("answer 29"))
  }
}
