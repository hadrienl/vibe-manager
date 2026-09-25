import Darwin
import Dispatch
import Foundation
import VibeApplication
import VibeDomain
import VibeProcess

public actor PTYTerminalSession: VibeApplication.TerminalSession {
  private static let forcedStopTimeout = Duration.seconds(2)
  private static let statePollInterval = Duration.milliseconds(20)
  private static let exitPollAttempts = 50
  // A subscriber that stops draining its stream must not grow the application's memory without
  // bound. Each queued event holds at most one coalescing window of output, so this caps a stalled
  // subscriber at a few seconds of backlog; beyond that the oldest output is dropped and the gap is
  // reported, exactly as the bounded history does.
  private static let subscriberBufferLimit = 512

  public nonisolated let id: SessionID

  private let terminal: PseudoTerminal
  private let reader: TerminalOutputReader
  private nonisolated let writer: TerminalInputWriter
  private let exitQueue: DispatchQueue

  private var historyBuffer: TerminalHistory
  private var currentState: TerminalProcessState
  private var subscribers: [UUID: AsyncStream<TerminalEvent>.Continuation] = [:]
  private var exitSource: DispatchSourceProcess?
  private var lastSize: TerminalSize
  private var isReaderFinished = false
  /// The process source said the child exited.
  private var hasExited = false
  private var isFinalized = false
  /// The state the session ended in, held until the reader has handed over its last bytes.
  private var finalState: TerminalProcessState?
  /// Every byte read has reached the history and the subscribers: the session can say it ended.
  private var isReaderDrained = false
  private var hasEnded = false

  public static func start(id: SessionID, spec: TerminalSpec) throws -> PTYTerminalSession {
    let terminal = try PseudoTerminalLauncher.launch(spec)
    let session = PTYTerminalSession(id: id, terminal: terminal, spec: spec)
    // The initial input is enqueued before the session handle is handed out, so a caller that
    // writes immediately cannot get its bytes in front of it: the writer queue keeps the order.
    if let initialInput = spec.initialInput, !initialInput.isEmpty {
      session.writer.write([UInt8](initialInput.utf8))
    }
    Task { await session.begin() }
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
    ChildProcessGroupGuard.register(terminal.processGroupIdentifier)
  }

  private func begin() {
    transition(to: .running(processIdentifier: terminal.processIdentifier))
    observeProcessExit()

    Task { [reader] in
      // A single consumer loop keeps output in the order it was read; dispatching one task per
      // chunk would let the actor interleave them arbitrarily.
      for await event in reader.events {
        await self.consume(event)
      }
      self.readerDidDrain()
    }
  }

  public func attach() -> TerminalAttachment {
    let subscriberID = UUID()
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let stream = AsyncStream<TerminalEvent>(
      bufferingPolicy: .bufferingNewest(Self.subscriberBufferLimit)
    ) { continuation = $0 }

    if let continuation {
      if hasEnded {
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

  // `isFinalized` rather than the state: between the two, the process is reaped and its
  // descriptors closed while the last output is still being handed over.
  public func write(_ bytes: [UInt8]) {
    guard !isFinalized else { return }
    writer.write(bytes)
  }

  public func resize(to size: TerminalSize) {
    guard size.isUsable, size != lastSize, !isFinalized else { return }
    lastSize = size
    terminal.resize(to: size)
  }

  /// Tells the program to draw itself again, at the size it already has.
  ///
  /// A view that attaches to a program already running is given its history, and a full-screen
  /// program's history is a stream of redraws cut wherever the replay buffer was trimmed. The
  /// kernel only raises `SIGWINCH` when the size changes, and a view reopened at the same size
  /// changes nothing — so the signal is sent here, to the group the child leads.
  public func redraw() {
    guard !isFinalized else { return }
    terminal.signalProcessGroup(SIGWINCH)
  }

  public func stop(gracePeriod: Duration) async {
    guard !isFinalized else { return await waitForEnd() }
    // A process cannot finish exiting while its output waits to be read.
    reader.stopThrottling()

    terminal.signalProcessGroup(SIGTERM)
    if await waitForCompletion(within: gracePeriod) { return sweepGroup() }

    terminal.signalProcessGroup(SIGKILL)
    if await waitForCompletion(within: Self.forcedStopTimeout) { return sweepGroup() }

    // The process is unreachable — a zombie parent or a stuck kernel wait. The session must
    // still release its descriptors and report an outcome, but the group may well be alive, so
    // the outcome says it is unknown rather than claiming a kill that was never confirmed.
    // Closing and archiving read this state to warn instead of promising nothing is left.
    finalize(
      with: .failed(.processOutcomeUnknown(processIdentifier: terminal.processIdentifier)),
      didReapProcess: false
    )
    await waitForEnd()
  }

  public func kill() async {
    guard !isFinalized else { return await waitForEnd() }
    reader.stopThrottling()
    terminal.signalProcessGroup(SIGKILL)
    if await waitForCompletion(within: Self.forcedStopTimeout) { return sweepGroup() }
    finalize(
      with: .failed(.processOutcomeUnknown(processIdentifier: terminal.processIdentifier)),
      didReapProcess: false
    )
    await waitForEnd()
  }

  /// A session stopped on purpose leaves nothing behind. The agent may have exited on `SIGTERM`
  /// while a child it started ignores it: the child is still in the group the agent led, with no
  /// terminal and nobody to see it. The group outlives its leader only while it has members, and
  /// no process can be given its number meanwhile, so it is still this session's to kill.
  private func sweepGroup() {
    guard Darwin.kill(-terminal.processGroupIdentifier, 0) == 0 else { return }
    terminal.signalProcessGroup(SIGKILL)
  }

  var processIdentifierForTesting: pid_t {
    terminal.processIdentifier
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
    // The exit status is authoritative. The last lines the process wrote are not lost for it: the
    // slave held open kept them in the kernel, and `finalize` drains them.
    hasExited = true
    await reapProcess()
  }

  private enum ReapOutcome {
    case reaped(status: Int32)
    case alreadyReaped
    case stillRunning
  }

  private func reapProcess() async {
    guard !isFinalized else { return }

    switch await pollForExit() {
    case .reaped(let status):
      guard !isFinalized else { return }
      finalize(with: Self.state(forWaitStatus: status), didReapProcess: true)
    case .alreadyReaped:
      // The child is gone but its status was collected elsewhere.
      guard !isFinalized, isReaderFinished || hasExited else { return }
      finalize(with: .exited(code: 0), didReapProcess: true)
    case .stillRunning:
      guard !isFinalized, isReaderFinished, !hasExited else { return }
      await reclaimRunningProcess()
    }
  }

  // The pseudo terminal reached end of file while the child is still alive — it closed its tty
  // descriptors, or a grandchild kept the slave open. Reclaiming the group is the only honest
  // outcome: reporting a clean exit here would both mislabel a crash and release the process
  // group from the shutdown guard while it is still running.
  private func reclaimRunningProcess() async {
    terminal.signalProcessGroup(SIGKILL)

    switch await pollForExit() {
    case .reaped(let status):
      guard !isFinalized else { return }
      finalize(with: Self.state(forWaitStatus: status), didReapProcess: true)
    case .alreadyReaped:
      guard !isFinalized else { return }
      finalize(with: .terminated(signal: SIGKILL), didReapProcess: true)
    case .stillRunning:
      guard !isFinalized else { return }
      finalize(
        with: .failed(.processOutcomeUnknown(processIdentifier: terminal.processIdentifier)),
        didReapProcess: false
      )
    }
  }

  private func pollForExit() async -> ReapOutcome {
    var status: Int32 = 0
    var attempts = 0

    while true {
      errno = 0
      let result = waitpid(terminal.processIdentifier, &status, WNOHANG)
      if result == terminal.processIdentifier { return .reaped(status: status) }
      if result < 0 { return errno == ECHILD ? .alreadyReaped : .stillRunning }

      attempts += 1
      guard attempts < Self.exitPollAttempts else { return .stillRunning }
      try? await Task.sleep(for: Self.statePollInterval)
      guard !isFinalized else { return .stillRunning }
    }
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

  /// A stop returns once the session said it ended, as it always has: finalized, it is only
  /// handing over its last output, which takes one pass of the consumer loop.
  private func waitForEnd() async {
    _ = await waitForCompletion(within: Self.forcedStopTimeout)
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

  // The process group stays registered with the shutdown guard until the child's status has
  // actually been collected: an unreaped group may still be alive, and dropping it here would
  // hide it from the `atexit` net that keeps orphans from surviving the application.
  private func finalize(with state: TerminalProcessState, didReapProcess: Bool) {
    guard !isFinalized else { return }
    isFinalized = true
    finalState = state

    exitSource?.cancel()
    exitSource = nil
    // The writer is drained before the reader closes the descriptor it shares.
    writer.close()
    // Its last bytes are yielded before its stream ends; the consumer loop delivers them, then
    // `readerDidDrain` says the session ended — output first, the exit after it.
    reader.finish()
    terminal.closeSlave()
    if didReapProcess {
      ChildProcessGroupGuard.unregister(terminal.processGroupIdentifier)
    }
    endIfDrained()
  }

  private func readerDidDrain() {
    isReaderDrained = true
    endIfDrained()
  }

  private func endIfDrained() {
    guard isReaderDrained, let finalState, !hasEnded else { return }
    hasEnded = true
    transition(to: finalState)
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
      guard case .dropped(let discarded) = continuation.yield(event) else { continue }
      // The subscriber fell far enough behind that its oldest event was evicted. Tell it how much
      // output it lost so it can show the gap rather than silently rendering a corrupt stream. A
      // dropped state change needs no notice: the current state is always readable from `state()`,
      // and the subscriber re-reads it when the stream ends.
      if case .output(let bytes) = discarded {
        _ = continuation.yield(.historyTruncated(droppedByteCount: bytes.count))
      }
    }
  }
}
