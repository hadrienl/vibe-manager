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
  private(set) var resizes: [TerminalSize] = []

  func write(_ bytes: [UInt8]) {}
  func resize(to size: TerminalSize) { resizes.append(size) }
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
  private(set) var startCount = 0
  private(set) var startedSpecs: [TerminalSpec] = []

  init(failure: TerminalError? = nil) {
    self.failure = failure
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    if let failure { throw failure }
    startCount += 1
    startedSpecs.append(spec)
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
  let model = TerminalPaneModel(
    sessionID: id, supervisor: supervisor, spec: makeSpec(), viewportTimeout: .zero)

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
    spec: makeSpec(),
    viewportTimeout: .zero
  )

  await model.start()

  #expect(model.session == nil)
  #expect(model.failure?.message.contains("/bin/nope") == true)
  #expect(model.failure?.suggestion?.isEmpty == false)
  #expect(model.status == .failed(message: model.failure?.message ?? ""))
}

@MainActor
@Test("A pane whose process has finished can be started again")
func paneRestartsAfterItsProcessFinished() async throws {
  let id = SessionID()
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: id, supervisor: supervisor, spec: makeSpec(), viewportTimeout: .zero)

  await model.start()
  #expect(model.session != nil)

  await supervisor.emit(.exited(code: 0), for: id)
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.status == .exited(code: 0))

  await model.start()
  #expect(await supervisor.startCount == 2)
  #expect(model.session != nil)
  #expect(model.status == .starting)
}

@MainActor
@Test("A restart carries the plan it was given, not the one the pane was built with")
func paneRestartsWithTheGivenSpec() async throws {
  let id = SessionID()
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: id, supervisor: supervisor, spec: makeSpec(), viewportTimeout: .zero)

  await model.start()
  await supervisor.emit(.exited(code: 0), for: id)
  try await Task.sleep(for: .milliseconds(50))

  var replacement = makeSpec()
  replacement.arguments = ["--resume", "abc"]
  await model.start(spec: replacement)

  #expect(await supervisor.startedSpecs.last?.arguments == ["--resume", "abc"])
}

@MainActor
@Test("Starting a pane that is already running changes nothing")
func paneIgnoresRedundantStart() async throws {
  let id = SessionID()
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: id, supervisor: supervisor, spec: makeSpec(), viewportTimeout: .zero)

  await model.start()
  await supervisor.emit(.running(processIdentifier: 42), for: id)
  try await Task.sleep(for: .milliseconds(50))

  await model.start()

  #expect(await supervisor.startCount == 1)
  #expect(model.status == .running)
}

@MainActor
@Test("The process is started at the size the surface measured, not at a placeholder")
func paneStartsAtTheMeasuredSize() async throws {
  let id = SessionID()
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: id,
    supervisor: supervisor,
    spec: makeSpec(),
    viewportTimeout: .seconds(5)
  )

  async let started: Void = model.start()
  await Task.yield()
  await model.reportViewportSize(TerminalSize(columns: 197, rows: 51))
  await started

  let spec = try #require(await supervisor.startedSpecs.first)
  #expect(spec.initialSize == TerminalSize(columns: 197, rows: 51))
}

@MainActor
@Test("A pane nobody measured still starts, rather than waiting forever")
func paneStartsWithoutAMeasurement() async throws {
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: SessionID(),
    supervisor: supervisor,
    spec: makeSpec(),
    viewportTimeout: .zero
  )

  await model.start()

  let spec = try #require(await supervisor.startedSpecs.first)
  #expect(spec.initialSize == TerminalSize.default)
  #expect(model.session != nil)
}

@MainActor
@Test("A size measured once the process runs is forwarded to it")
func laterMeasurementsResizeTheProcess() async throws {
  let id = SessionID()
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: id,
    supervisor: supervisor,
    spec: makeSpec(),
    viewportTimeout: .zero
  )
  await model.start()

  await model.reportViewportSize(TerminalSize(columns: 120, rows: 40))

  let session = try #require(await supervisor.session(for: id) as? FakeTerminalSession)
  #expect(await session.resizes == [TerminalSize(columns: 120, rows: 40)])
}

@MainActor
@Test("A measurement of nothing is ignored rather than passed on as a size")
func emptyMeasurementsAreIgnored() async throws {
  let supervisor = FakeSupervisor()
  let model = TerminalPaneModel(
    sessionID: SessionID(),
    supervisor: supervisor,
    spec: makeSpec(),
    viewportTimeout: .zero
  )

  await model.reportViewportSize(TerminalSize(columns: 0, rows: 0))
  await model.start()

  let spec = try #require(await supervisor.startedSpecs.first)
  #expect(spec.initialSize == TerminalSize.default)
}
