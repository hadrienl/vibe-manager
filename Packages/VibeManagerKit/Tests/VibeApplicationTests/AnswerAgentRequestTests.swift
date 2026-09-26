import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private let t1 = Date(timeIntervalSince1970: 4_000_000)

/// The terminals of every session, recording what each is sent.
private actor Terminals {
  private(set) var written: [SessionID: [[UInt8]]] = [:]
  var running: Set<SessionID> = []
  /// Called after each write, as a CLI would react to a key.
  var onWrite: (@Sendable (SessionID) async -> Void)?

  func write(_ bytes: [UInt8], to id: SessionID) async -> Bool {
    guard running.contains(id) else { return false }
    written[id, default: []].append(bytes)
    await onWrite?(id)
    return true
  }

  func run(_ id: SessionID) {
    running.insert(id)
  }

  func setOnWrite(_ action: @escaping @Sendable (SessionID) async -> Void) {
    onWrite = action
  }
}

/// Reads permissions as Claude Code reports them, and answers them with its digits.
private struct PermissionDecoder: AgentSignalDecoding {
  let approvalAnswerKeys: Set<[UInt8]> = [[0x31]]

  var answerKeymap: (any AgentAnswerKeymap)? {
    TwoStepKeymap()
  }

  func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "start": return .channelConfirmed
    case "ask":
      let command = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
      return .questionAsked(
        .approval, tool: "Bash",
        notice: AgentRequestNotice(
          content: .permission(
            AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
          reference: AgentToolReference(tool: "Bash", subject: command), isShown: true))
    case "done":
      let command = event.payload.map { String(decoding: $0, as: UTF8.self) }
      return .toolFinished("Bash", subject: command)
    default: return nil
    }
  }
}

/// Allows with one key, refuses with two, to see what happens between two keystrokes.
private struct TwoStepKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.allowOnce, .deny]
  }

  func keystrokes(for answer: AgentAnswer, to content: AgentRequestContent) -> [[UInt8]]? {
    switch answer {
    case .allowOnce: return [[0x31]]
    case .deny: return [[0x33], [0x0D]]
    default: return nil
    }
  }
}

private struct Fixture {
  let logs = ScriptedActivityLogs()
  let tracker: TrackAgentActivity
  let terminals = Terminals()
  let answer: AnswerAgentRequest

  init() {
    tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: TestClock(t1))
    let terminals = terminals
    answer = AnswerAgentRequest(
      tracker: tracker,
      write: { id, bytes in await terminals.write(bytes, to: id) },
      sleep: { _ in })
  }

  /// A running session whose agent asks to run `command`.
  func asking(_ command: String) async -> (SessionID, AgentRequestID) {
    let id = SessionID()
    await terminals.run(id)
    await tracker.processStarted(id, decoder: PermissionDecoder())
    _ = await following(logs, id)
    await logs.write("start", at: t1, for: id)
    await logs.write("ask", at: t1, for: id, payload: command)
    _ = await eventually(tracker, id) { $0?.requests.count == 1 }
    let request = await tracker.state(for: id)?.requests.first?.id
    return (id, request ?? AgentRequestID(sessionID: id, key: "none"))
  }
}

@Suite("Answering a request from the palette")
struct AnswerAgentRequestTests {
  @Test("The answer is typed into the terminal of the request's session, and nowhere else")
  func routed() async {
    let fixture = Fixture()
    let (first, _) = await fixture.asking("touch a")
    let (second, request) = await fixture.asking("touch b")

    #expect(await fixture.answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[second] == [[0x31]])
    #expect(await fixture.terminals.written[first] == nil)
    // The agent is at work again at once, without waiting for the tool to end.
    #expect(await fixture.tracker.state(for: second)?.activity == .working)
    #expect(await fixture.tracker.state(for: first)?.requests.count == 1)
  }

  @Test("A request answered meanwhile, or not the first, gets nothing typed")
  func gone() async {
    let fixture = Fixture()
    let (id, request) = await fixture.asking("touch a")
    await fixture.logs.write("done", at: t1, for: id, payload: "touch a")
    _ = await eventually(fixture.tracker, id) { $0?.requests.isEmpty == true }

    #expect(await fixture.answer(.allowOnce, to: request) == .requestGone)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("An answer the request does not offer is not typed")
  func notOffered() async {
    let fixture = Fixture()
    let (id, request) = await fixture.asking("touch a")
    #expect(await fixture.answer(.allowAlways, to: request) == .notAnswerable)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("A request that goes away between two keystrokes stops the answer halfway")
  func interrupted() async {
    let fixture = Fixture()
    let (id, request) = await fixture.asking("touch a")
    let logs = fixture.logs
    let tracker = fixture.tracker
    await fixture.terminals.setOnWrite { id in
      await logs.write("done", at: t1, for: id, payload: "touch a")
      _ = await eventually(tracker, id) { $0?.requests.isEmpty == true }
    }
    #expect(await fixture.answer(.deny, to: request) == .interrupted)
    #expect(await fixture.terminals.written[id] == [[0x33]])
  }

  @Test("A session whose terminal is gone is not answered")
  func noTerminal() async {
    let fixture = Fixture()
    let (_, request) = await fixture.asking("touch a")
    let orphan = AgentRequestID(sessionID: SessionID(), key: request.key)
    #expect(await fixture.answer(.allowOnce, to: orphan) == .requestGone)
  }

  @Test("How each request can be answered is published with the session's state")
  func published() async {
    let fixture = Fixture()
    let updates = await fixture.tracker.updates()
    let (_, request) = await fixture.asking("touch a")
    var answering: AgentRequestAnswering?
    for await update in updates where update.answering[request] != nil {
      answering = update.answering[request]
      break
    }
    #expect(answering == .fromPalette([.allowOnce, .deny]))
  }

  @Test("Requests are written for the next launch, and an adopted agent finds them again")
  func persisted() async {
    let logs = ScriptedActivityLogs()
    let store = MemoryActivityStore()
    let tracker = makeTracker(logs: logs, store: store, clock: TestClock(t1))
    let id = SessionID()
    await tracker.processStarted(id, decoder: PermissionDecoder())
    _ = await following(logs, id)
    await logs.write("start", at: t1, for: id)
    await logs.write("ask", at: t1, for: id, payload: "touch a")
    _ = await eventually(tracker, id) { $0?.requests.count == 1 }
    await tracker.flush()
    #expect(await store.stored[id]?.requests.count == 1)

    let relaunched = makeTracker(logs: logs, store: store, clock: TestClock(t1))
    await relaunched.processAdopted(id, decoder: PermissionDecoder())
    #expect(await relaunched.state(for: id)?.requests.map(\.reference.subject) == ["touch a"])
  }
}
