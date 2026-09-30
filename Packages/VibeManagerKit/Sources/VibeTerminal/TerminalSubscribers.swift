import Foundation
import VibeApplication

/// When a subscriber that reads pulses is told of output (#248): at once on the first output, then
/// at most once per interval, and once more at the end of the interval when output came during it
/// — so the last block of a burst is never left unannounced.
struct PulseGate {
  enum Decision: Equatable {
    /// Tell the subscriber now.
    case emit
    /// Tell it at this instant, unless a pulse is already planned.
    case schedule(at: ContinuousClock.Instant)
    /// A pulse is already planned: it covers this output.
    case covered
  }

  let interval: Duration
  private var lastEmitted: ContinuousClock.Instant?
  private var isScheduled = false

  init(interval: Duration) {
    self.interval = interval
  }

  mutating func output(at now: ContinuousClock.Instant) -> Decision {
    if isScheduled { return .covered }
    guard let lastEmitted, now - lastEmitted < interval else {
      self.lastEmitted = now
      return .emit
    }
    isScheduled = true
    return .schedule(at: lastEmitted + interval)
  }

  /// The planned pulse is due, and goes out now.
  mutating func scheduledPulseFired(at now: ContinuousClock.Instant) {
    isScheduled = false
    lastEmitted = now
  }
}

/// The subscribers of one terminal and what each of them reads (#248), shared by the two sessions
/// that serve them: the one whose process runs here and the one the terminal host runs.
///
/// Called by the session's actor, in order, and by the pulses it plans for later, from wherever they
/// fall due: its state is behind a lock, never held while a stream is written to — ending a stream
/// calls back into it.
final class TerminalSubscribers: @unchecked Sendable {
  private struct Subscriber {
    let continuation: AsyncStream<TerminalEvent>.Continuation
    let interest: TerminalEventInterest
    var gate: PulseGate?
  }

  /// A pulse a subscriber is owed at `deadline`.
  struct PlannedPulse: Sendable {
    let subscriberID: UUID
    let deadline: ContinuousClock.Instant
  }

  // A subscriber that stops draining its stream must not grow the application's memory without
  // bound. Each queued event holds at most one coalescing window of output, so this caps a stalled
  // subscriber at a few seconds of backlog; beyond that the oldest output is dropped and the gap is
  // reported, exactly as the bounded history does.
  private static let bufferLimit = 512

  private let lock = NSLock()
  private var subscribers: [UUID: Subscriber] = [:]
  private var lastOutput: ContinuousClock.Instant?
  /// What delivers a planned pulse when it falls due: a task that waits for it, unless a test
  /// delivers them itself.
  private let schedule: @Sendable (PlannedPulse, TerminalSubscribers) -> Void

  init(
    schedule: @escaping @Sendable (PlannedPulse, TerminalSubscribers) -> Void = { pulse, owner in
      Task { [weak owner] in
        try? await Task.sleep(until: pulse.deadline, clock: .continuous)
        owner?.deliverPulse(to: pulse.subscriberID)
      }
    }
  ) {
    self.schedule = schedule
  }

  /// When the process last wrote something.
  var lastOutputAt: ContinuousClock.Instant? {
    lock.withLock { lastOutput }
  }

  /// What each subscriber reads, for the tests that check nobody reads more than it needs.
  var interests: [TerminalEventInterest] {
    lock.withLock { subscribers.values.map(\.interest) }
  }

  /// The attachment of a new subscriber reading `interest`: its stream is already finished when the
  /// session has ended, and it is let go of when its reader drops the stream.
  func attach(
    _ interest: TerminalEventInterest,
    state: TerminalProcessState,
    history: TerminalHistorySnapshot,
    hasEnded: Bool
  ) -> TerminalAttachment {
    let (stream, continuation) = AsyncStream<TerminalEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(Self.bufferLimit))
    if hasEnded {
      continuation.finish()
    } else {
      let id = UUID()
      var gate: PulseGate?
      if case .pulses(let interval) = interest { gate = PulseGate(interval: interval) }
      lock.withLock {
        subscribers[id] = Subscriber(continuation: continuation, interest: interest, gate: gate)
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: id) }
      }
    }
    return TerminalAttachment(state: state, history: history, events: stream)
  }

  /// Hands a block of output, and the bytes the history dropped for it, to whoever reads them.
  /// Returns the pulses planned for later, which are already scheduled.
  @discardableResult
  func output(
    _ bytes: [UInt8],
    historyDropped dropped: Int,
    at now: ContinuousClock.Instant = .now
  ) -> [PlannedPulse] {
    var readers: [AsyncStream<TerminalEvent>.Continuation] = []
    var pulsed: [AsyncStream<TerminalEvent>.Continuation] = []
    var planned: [PlannedPulse] = []
    lock.withLock {
      lastOutput = now
      for (id, subscriber) in subscribers {
        switch subscriber.interest {
        case .everything:
          readers.append(subscriber.continuation)
        case .state:
          continue
        case .pulses:
          guard var gate = subscriber.gate else { continue }
          switch gate.output(at: now) {
          case .emit: pulsed.append(subscriber.continuation)
          case .schedule(let deadline):
            planned.append(PlannedPulse(subscriberID: id, deadline: deadline))
          case .covered: break
          }
          subscribers[id]?.gate = gate
        }
      }
    }
    for continuation in readers {
      Self.yield(.output(bytes), to: continuation)
      if dropped > 0 { Self.yield(.historyTruncated(droppedByteCount: dropped), to: continuation) }
    }
    for continuation in pulsed { continuation.yield(.outputPulse) }
    for pulse in planned { schedule(pulse, self) }
    return planned
  }

  /// A planned pulse is due.
  func deliverPulse(to id: UUID, at now: ContinuousClock.Instant = .now) {
    let continuation: AsyncStream<TerminalEvent>.Continuation? = lock.withLock {
      subscribers[id]?.gate?.scheduledPulseFired(at: now)
      return subscribers[id]?.continuation
    }
    continuation?.yield(.outputPulse)
  }

  /// Bytes lost before they reached the history — trimmed from another buffer on their way here.
  func truncated(_ byteCount: Int) {
    for continuation in continuations(where: { $0 == .everything }) {
      Self.yield(.historyTruncated(droppedByteCount: byteCount), to: continuation)
    }
  }

  func stateChanged(_ state: TerminalProcessState) {
    for continuation in continuations(where: { _ in true }) {
      Self.yield(.stateChanged(state), to: continuation)
    }
  }

  /// The session ended: every stream ends with it.
  func finishAll() {
    let all = lock.withLock {
      defer { subscribers.removeAll() }
      return subscribers.values.map(\.continuation)
    }
    for continuation in all { continuation.finish() }
  }

  private func continuations(
    where reads: (TerminalEventInterest) -> Bool
  ) -> [AsyncStream<TerminalEvent>.Continuation] {
    lock.withLock { subscribers.values.filter { reads($0.interest) }.map(\.continuation) }
  }

  private static func yield(
    _ event: TerminalEvent, to continuation: AsyncStream<TerminalEvent>.Continuation
  ) {
    guard case .dropped(let discarded) = continuation.yield(event) else { return }
    // The subscriber fell far enough behind that its oldest event was evicted. Tell it how much
    // output it lost so it can show the gap rather than silently rendering a corrupt stream. A
    // dropped state change needs no notice: the current state is always readable from `state()`,
    // and the subscriber re-reads it when the stream ends.
    if case .output(let lost) = discarded {
      _ = continuation.yield(.historyTruncated(droppedByteCount: lost.count))
    }
  }
}
