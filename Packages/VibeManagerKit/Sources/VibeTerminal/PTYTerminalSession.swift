import Darwin
import Dispatch
import Foundation
import VibeApplication
import VibeDomain

public actor PTYTerminalSession: VibeApplication.TerminalSession {
  private static let exitDrainTimeout = Duration.milliseconds(500)
  private static let forcedStopTimeout = Duration.seconds(2)
  private static let statePollInterval = Duration.milliseconds(20)

  public nonisolated let id: SessionID

  private let terminal: PseudoTerminal
  private let reader: TerminalOutputReader
  private let writer: TerminalInputWriter
  private let exitQueue: DispatchQueue

  private var historyBuffer: TerminalHistory
  private var currentState: TerminalProcessState
  private var subscribers: [UUID: AsyncStream<TerminalEvent>.Continuation] = [:]
  private var exitSource: DispatchSourceProcess?
  private var lastSize: TerminalSize
  private var isReaderFinished = false
  private var isFinalized = false

  public static func start(id: SessionID, spec: TerminalSpec) throws -> PTYTerminalSession {
    let terminal = try PseudoTerminalLauncher.launch(spec)
    let session = PTYTerminalSession(id: id, terminal: terminal, spec: spec)
    Task { await session.begin(initialInput: spec.initialInput) }
    return session
  }

  private init(id: SessionID, terminal: PseudoTerminal, spec: TerminalSpec) {
    self.id = id
    self.terminal = terminal
    reader = TerminalOutputReader(descriptor: terminal.masterDescriptor)
    writer = TerminalInputWriter(descriptor: terminal.masterDescriptor)
    exitQueue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal.exit")
    historyBuffer = TerminalHistory(limits: spec.scrollback)
    currentState = .starting
    lastSize = spec.initialSize
    TerminalProcessGroupGuard.register(terminal.processGroupIdentifier)
  }

  private func begin(initialInput: String?) {
    transition(to: .running(processIdentifier: terminal.processIdentifier))
    observeProcessExit()

    Task { [reader] in
      // A single consumer loop keeps output in the order it was read; dispatching one task per
      // chunk would let the actor interleave them arbitrarily.
      for await event in reader.events {
        await self.consume(event)
      }
    }

    if let initialInput, !initialInput.isEmpty {
      writer.write([UInt8](initialInput.utf8))
    }
  }

  public func attach() -> TerminalAttachment {
    let subscriberID = UUID()
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let stream = AsyncStream<TerminalEvent> { continuation = $0 }

    if let continuation {
      if isFinalized {
        continuation.finish()
      } else {
        subscribers[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
          guard let self else { return }
          Task { await self.removeSubscriber(subscriberID) }
        }
      }
    }

    return TerminalAttachment(state: currentState, history: historyBuffer.snapshot, events: stream)
  }

  public func state() -> TerminalProcessState {
    currentState
  }

  public func history() -> TerminalHistorySnapshot {
    historyBuffer.snapshot
  }

  public func write(_ bytes: [UInt8]) {
    guard !currentState.isFinished else { return }
    writer.write(bytes)
  }

  public func resize(to size: TerminalSize) {
    guard size.isUsable, size != lastSize, !currentState.isFinished else { return }
    lastSize = size
    terminal.resize(to: size)
  }

  public func stop(gracePeriod: Duration) async {
    guard !currentState.isFinished else { return }

    terminal.signalProcessGroup(SIGTERM)
    if await waitForCompletion(within: gracePeriod) { return }

    terminal.signalProcessGroup(SIGKILL)
    if await waitForCompletion(within: Self.forcedStopTimeout) { return }

    // The process is unreachable — a zombie parent or a stuck kernel wait. The session must
    // still release its descriptors and report an outcome.
    finalize(with: .terminated(signal: SIGKILL))
  }

  public func kill() async {
    guard !currentState.isFinished else { return }
    terminal.signalProcessGroup(SIGKILL)
    if await waitForCompletion(within: Self.forcedStopTimeout) { return }
    finalize(with: .terminated(signal: SIGKILL))
  }

  private func consume(_ event: TerminalReadEvent) async {
    switch event {
    case .bytes(let bytes):
      let dropped = historyBuffer.append(bytes)
      broadcast(.output(bytes))
      if dropped > 0 {
        broadcast(.historyTruncated(droppedByteCount: dropped))
      }
      reader.didConsume(byteCount: bytes.count)
    case .endOfFile:
      isReaderFinished = true
      await reapProcess()
    }
  }

  private func observeProcessExit() {
    let source = DispatchSource.makeProcessSource(
      identifier: terminal.processIdentifier,
      eventMask: .exit,
      queue: exitQueue
    )
    // The session is bound strongly before the task is created: a task closure that captured the
    // weak binding itself would capture a mutable variable, which Swift 6.1 rejects as sendable.
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.handleProcessExit() }
    }
    exitSource = source
    source.resume()
  }

  private func handleProcessExit() async {
    guard !isFinalized else { return }

    // The exit status is authoritative, but the kernel buffer may still hold the last lines the
    // process wrote — exactly the ones that explain a failure — so the reader is given time.
    let deadline = ContinuousClock.now + Self.exitDrainTimeout
    while !isReaderFinished, ContinuousClock.now < deadline {
      try? await Task.sleep(for: Self.statePollInterval)
    }
    await reapProcess()
  }

  private func reapProcess() async {
    guard !isFinalized else { return }

    var status: Int32 = 0
    var result = waitpid(terminal.processIdentifier, &status, WNOHANG)
    var attempts = 0
    while result == 0, attempts < 50 {
      try? await Task.sleep(for: Self.statePollInterval)
      guard !isFinalized else { return }
      result = waitpid(terminal.processIdentifier, &status, WNOHANG)
      attempts += 1
    }

    guard result == terminal.processIdentifier else {
      // The child is gone but its status is unreachable; the pseudo terminal reported the end.
      guard isReaderFinished else { return }
      finalize(with: .exited(code: 0))
      return
    }
    finalize(with: Self.state(forWaitStatus: status))
  }

  // The wait status macros are not imported into Swift: the low seven bits hold the terminating
  // signal, and a value of zero there means a normal exit whose code sits in the next byte.
  private static func state(forWaitStatus status: Int32) -> TerminalProcessState {
    let signalNumber = status & 0x7f
    guard signalNumber != 0 else {
      return .exited(code: (status >> 8) & 0xff)
    }
    return .terminated(signal: signalNumber)
  }

  private func waitForCompletion(within timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if currentState.isFinished { return true }
      try? await Task.sleep(for: Self.statePollInterval)
    }
    return currentState.isFinished
  }

  private func transition(to state: TerminalProcessState) {
    guard currentState != state else { return }
    currentState = state
    broadcast(.stateChanged(state))
  }

  private func finalize(with state: TerminalProcessState) {
    guard !isFinalized else { return }
    isFinalized = true

    transition(to: state)
    exitSource?.cancel()
    exitSource = nil
    // The writer is drained before the reader closes the descriptor it shares.
    writer.close()
    reader.finish()
    TerminalProcessGroupGuard.unregister(terminal.processGroupIdentifier)

    for continuation in subscribers.values {
      continuation.finish()
    }
    subscribers.removeAll()
  }

  private func removeSubscriber(_ subscriberID: UUID) {
    subscribers[subscriberID] = nil
  }

  private func broadcast(_ event: TerminalEvent) {
    for continuation in subscribers.values {
      continuation.yield(event)
    }
  }
}
