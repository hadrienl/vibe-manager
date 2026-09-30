import Foundation
import VibeApplication
import VibeDomain

/// A terminal whose process runs in the terminal host, as the application sees it.
///
/// It keeps its own replay buffer, fed by the host, so that every `attach()` the application makes
/// — the pane, the surface, the exit watch, the agent observer — is answered here, in one
/// consistent value, exactly as `PTYTerminalSession` answers it: nobody above the supervisor can
/// tell the two apart.
public actor HostedTerminalSession: HostedTerminal {
  public nonisolated let id: TerminalID
  private let supervisor: HostedTerminalSupervisor

  private var historyBuffer: TerminalHistory
  private var currentState: TerminalProcessState
  private var subscribers = TerminalSubscribers()
  private var hasEnded = false
  /// Set on a session taken back after a relaunch: the first size the view reports is followed by
  /// a redraw, so a full-screen program draws itself for the window it is now in.
  private var needsRedraw: Bool

  init(
    id: TerminalID,
    supervisor: HostedTerminalSupervisor,
    state: TerminalProcessState,
    scrollback: TerminalScrollbackLimits,
    needsRedraw: Bool
  ) {
    self.id = id
    self.supervisor = supervisor
    currentState = state
    historyBuffer = TerminalHistory(limits: scrollback)
    self.needsRedraw = needsRedraw
  }

  public func attach() -> TerminalAttachment {
    subscribe(.everything)
  }

  // Declared `async`, as the requirement is: a synchronous one would lose to the relay the
  // protocol's extension offers stand-ins, wherever the caller awaits.
  public func attach(_ interest: TerminalEventInterest) async -> TerminalAttachment {
    subscribe(interest)
  }

  private func subscribe(_ interest: TerminalEventInterest) -> TerminalAttachment {
    let events = subscribers.add(interest, hasEnded: hasEnded) { [weak self] subscriberID in
      guard let self else { return }
      Task { await self.removeSubscriber(subscriberID) }
    }
    return TerminalAttachment(state: currentState, history: historyBuffer.snapshot, events: events)
  }

  public func lastOutputAt() async -> ContinuousClock.Instant? {
    subscribers.lastOutputAt
  }

  /// What each subscriber reads, for the tests.
  var subscriberInterests: [TerminalEventInterest] {
    subscribers.interests
  }

  public func state() -> TerminalProcessState {
    currentState
  }

  public func history() -> TerminalHistorySnapshot {
    historyBuffer.snapshot
  }

  public func write(_ bytes: [UInt8]) async {
    guard !hasEnded, !bytes.isEmpty else { return }
    await supervisor.sendInput(bytes, to: id)
  }

  public func resize(to size: TerminalSize) async {
    guard size.isUsable, !hasEnded else { return }
    await supervisor.send(.resize(session: id, size: size))
    guard needsRedraw else { return }
    needsRedraw = false
    await supervisor.send(.redraw(session: id))
  }

  public func stop(gracePeriod: Duration) async {
    guard !hasEnded else { return }
    let milliseconds = Int(gracePeriod / .milliseconds(1))
    let reply = await supervisor.request(
      .stop(session: id, gracePeriodMilliseconds: milliseconds),
      timeout: gracePeriod + .seconds(5)
    )
    settle(with: reply)
  }

  public func kill() async {
    guard !hasEnded else { return }
    let reply = await supervisor.request(.kill(session: id), timeout: .seconds(5))
    settle(with: reply)
  }

  // MARK: - Fed by the supervisor, in the order the host sent it

  func receive(output bytes: [UInt8]) {
    let dropped = historyBuffer.append(bytes)
    deliver(output: bytes, historyDropped: dropped)
  }

  func receive(truncated byteCount: Int) {
    historyBuffer.noteDropped(byteCount)
    subscribers.truncated(byteCount)
  }

  /// The history the host already held has arrived, and this is the state it goes on from.
  func receiveAttached(state: TerminalProcessState, droppedByteCount: Int) {
    historyBuffer.noteDropped(droppedByteCount)
    apply(state)
  }

  func receive(state: TerminalProcessState) {
    apply(state)
  }

  /// The host is gone. Whatever it was running is either dead with it or unreachable, and the
  /// application can no longer tell which: it says so rather than claiming an exit.
  func connectionLost() {
    guard !hasEnded else { return }
    let processIdentifier: Int32
    if case .running(let pid) = currentState {
      processIdentifier = pid
    } else {
      processIdentifier = 0
    }
    apply(.failed(.processOutcomeUnknown(processIdentifier: processIdentifier)))
  }

  /// The host is gone, and the application has stopped what it ran for this session.
  func hostStopped() {
    guard !hasEnded else { return }
    apply(.failed(.hostStopped))
  }

  private func settle(with reply: TerminalHostMessage.Body?) {
    guard case .stopped(let state) = reply else { return connectionLost() }
    apply(state)
  }

  private func apply(_ state: TerminalProcessState) {
    guard !hasEnded else { return }
    if currentState != state {
      currentState = state
      subscribers.stateChanged(state)
    }
    guard state.isFinished else { return }
    hasEnded = true
    subscribers.finishAll()
  }

  private func removeSubscriber(_ subscriberID: UUID) {
    subscribers.remove(subscriberID)
  }

  /// Hands a block of output to whoever reads it, and waits for the pulses it planned.
  private func deliver(output bytes: [UInt8], historyDropped dropped: Int) {
    for pulse in subscribers.output(bytes, historyDropped: dropped) {
      Task { [weak self] in
        try? await Task.sleep(until: pulse.deadline, clock: .continuous)
        await self?.deliverPulse(to: pulse.subscriberID)
      }
    }
  }

  private func deliverPulse(to subscriberID: UUID) {
    subscribers.deliverPulse(to: subscriberID)
  }

}
