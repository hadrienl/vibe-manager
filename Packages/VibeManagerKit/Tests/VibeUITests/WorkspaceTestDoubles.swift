import Foundation
import VibeApplication
import VibeDomain

@testable import VibeUI

// The doubles the workspace suites share: one terminal supervisor, one fake terminal, one agent
// and one store, used by the restart suite and the restoration suite alike. Kept in one file in
// the manner of `AgentTestDoubles` and `TerminalTestSupport`, because three copies of a terminal
// double drift apart one fix at a time.

actor WorkspaceSupervisor: TerminalSupervisor {
  private(set) var startCount = 0
  private(set) var lastSpec: TerminalSpec?
  private var sessions: [SessionID: WorkspaceTerminal] = [:]
  private let failure: TerminalError?
  private var initialState: TerminalProcessState

  init(
    failure: TerminalError? = nil,
    initialState: TerminalProcessState = .running(processIdentifier: 4242)
  ) {
    self.failure = failure
    self.initialState = initialState
  }

  /// What the next process starts in, for a test whose second launch must not repeat the fate
  /// of its first.
  func nextProcessStarts(in state: TerminalProcessState) {
    initialState = state
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    if let failure { throw failure }
    startCount += 1
    lastSpec = spec
    let session = WorkspaceTerminal(id: id, state: initialState)
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    // Released as well as finished, exactly as `PTYTerminalSupervisor` does: a double that kept
    // the entry would let a test claim nothing is attached while the supervisor still holds it.
    await sessions.removeValue(forKey: id)?.finish(state: .exited(code: 0))
  }

  func stopAll(gracePeriod: Duration) {}

  func finish(id: SessionID, state: TerminalProcessState) async {
    await sessions[id]?.finish(state: state)
  }
}

actor WorkspaceTerminal: TerminalSession {
  nonisolated let id: SessionID
  private var current: TerminalProcessState
  private var continuations: [AsyncStream<TerminalEvent>.Continuation] = []

  init(id: SessionID, state: TerminalProcessState) {
    self.id = id
    current = state
  }

  func attach() -> TerminalAttachment {
    let state = current
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let events = AsyncStream<TerminalEvent> { continuation = $0 }
    if let continuation {
      if state.isFinished {
        continuation.finish()
      } else {
        continuations.append(continuation)
      }
    }
    return TerminalAttachment(
      state: state,
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: events
    )
  }

  func state() -> TerminalProcessState { current }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {
    finish(state: .exited(code: 0))
  }

  func kill() {
    finish(state: .terminated(signal: 9))
  }

  func finish(state: TerminalProcessState) {
    guard !current.isFinished else { return }
    current = state
    for continuation in continuations {
      continuation.yield(.stateChanged(state))
      continuation.finish()
    }
    continuations.removeAll()
  }
}

/// A door the detections wait at until the test opens it.
actor ProbeGate {
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    let waiting = self.waiting
    self.waiting = []
    for continuation in waiting { continuation.resume() }
  }
}

struct WorkspaceProvider: AgentProvider, AgentLaunchObserverProviding {
  /// How long the launch observer holds the launch open, in scheduler turns.
  var observerDelayYields = 0
  /// Holds every detection until the test opens it: what is on screen before one lands, however
  /// slow the machine.
  var probeGate: ProbeGate?

  func launchObserver(
    for _: SessionID,
    repository _: any SessionRepository
  ) -> any AgentLaunchObserver {
    WorkspaceSlowObserver(yields: observerDelayYields)
  }

  let descriptor = AgentDescriptor(
    id: AgentProviderID("stub"),
    displayName: "Stub Agent",
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true
    )
  )

  func availability(forceRefresh _: Bool) async -> AgentAvailability {
    await probeGate?.wait()
    return AgentAvailability(
      state: .available,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: .available,
        summary: "Stub Agent is ready.",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: []
      )
    )
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    var arguments: [String] = []
    if case .identifier(let identifier) = request.resume {
      arguments.append(contentsOf: ["--resume", identifier])
    }
    if let prompt = request.initialPrompt {
      arguments.append(prompt)
    }
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: arguments,
      environment: [:],
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

/// An observer that keeps a launch in flight for a known number of scheduler turns.
struct WorkspaceSlowObserver: AgentLaunchObserver {
  let yields: Int

  func launched(plan _: AgentLaunchPlan) async {
    for _ in 0..<yields { await Task.yield() }
  }

  func observe(output _: String) async {
    // The identifier this launch would reveal is not what these tests are about.
  }

  func finished() async {
    // Nothing was kept, so there is nothing to flush.
  }
}

struct WorkspaceRegistry: AgentProviderResolving {
  var providers: [WorkspaceProvider]

  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    var result: [AgentProviderID: AgentAvailability] = [:]
    for provider in providers {
      result[provider.descriptor.id] = await provider.availability(forceRefresh: forceRefresh)
    }
    return result
  }
}

actor WorkspaceRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func status(of id: SessionID) -> SessionStatus? {
    stored.first { $0.id == id }?.status
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }

  /// Archives the stored session the way the archiving use case would, for a test that needs the
  /// store to disagree with the value a caller is holding.
  func archive(_ id: SessionID) {
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
    try? stored[index].archive(at: stored[index].updatedAt)
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
    var session = stored[index]
    try transform(&session)
    stored[index] = session
    return session
  }
}
