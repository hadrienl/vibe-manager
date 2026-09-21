import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminalUI

private actor FakeTerminalSession: TerminalSession {
  nonisolated let id: SessionID
  private var currentState: TerminalProcessState = .starting
  private var continuations: [UUID: AsyncStream<TerminalEvent>.Continuation] = [:]

  init(id: SessionID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    let key = UUID()
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let stream = AsyncStream<TerminalEvent> { continuation = $0 }
    continuations[key] = continuation
    return TerminalAttachment(
      state: currentState,
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: stream
    )
  }

  func state() -> TerminalProcessState { currentState }
  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }
  func write(_ bytes: [UInt8]) {}
  func resize(to size: TerminalSize) {}
  func stop(gracePeriod: Duration) { emit(.exited(code: 0)) }
  func kill() { emit(.terminated(signal: SIGKILL)) }

  func emit(_ state: TerminalProcessState) {
    currentState = state
    for continuation in continuations.values {
      continuation.yield(.stateChanged(state))
    }
  }
}

private actor FakeSupervisor: TerminalSupervisor {
  private let failure: TerminalError?
  private var sessions: [SessionID: FakeTerminalSession] = [:]

  init(failure: TerminalError? = nil) {
    self.failure = failure
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    if let failure { throw failure }
    let session = FakeTerminalSession(id: id)
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    await sessions[id]?.stop(gracePeriod: gracePeriod)
  }

  func stopAll(gracePeriod: Duration) async {
    for session in sessions.values {
      await session.stop(gracePeriod: gracePeriod)
    }
  }

  func emit(_ state: TerminalProcessState, for id: SessionID) async {
    await sessions[id]?.emit(state)
  }
}

private func makeSpec() -> TerminalSpec {
  TerminalSpec(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  )
}

@MainActor
@Test("The pane reports the lifecycle of its session")
func paneFollowsSessionLifecycle() async throws {
  let id = SessionID()
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(sessionID: id, supervisor: supervisor, spec: makeSpec())

  await model.start()
  #expect(model.session != nil)

  await supervisor.emit(.running(processIdentifier: 1_234), for: id)
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.status == .running)

  await supervisor.emit(.exited(code: 3), for: id)
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.status == .exited(code: 3))
}

@MainActor
@Test("A launch failure is presented with its remediation and without technical detail")
func paneReportsLaunchFailure() async {
  let supervisor = FakeSupervisor(failure: .executableNotFound(path: "/bin/nope"))
  let model = TerminalPaneModel(
    sessionID: SessionID(),
    supervisor: supervisor,
    spec: makeSpec()
  )

  await model.start()

  #expect(model.session == nil)
  #expect(model.failure?.message.contains("/bin/nope") == true)
  #expect(model.failure?.suggestion?.isEmpty == false)
  #expect(model.status == .failed(message: model.failure?.message ?? ""))
}
