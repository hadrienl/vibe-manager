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
    /// Output its stream lost to make room for the notice of an earlier loss, told with the next
    /// notice (#367).
    var unannouncedLoss = 0
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

  /// Hands a block of output to whoever reads it. Returns the pulses planned for later, which are
  /// already scheduled.
  ///
  /// What the history trims to make room for it is not told: those bytes were delivered already,
  /// and each reader trims its own copy by itself. Told, it took half of a lagging reader's
  /// bounded stream, and made it lose real output sooner (#364).
  @discardableResult
  func output(
    _ bytes: [UInt8],
    at now: ContinuousClock.Instant = .now
  ) -> [PlannedPulse] {
    var readers: [Reader] = []
    var pulsed: [AsyncStream<TerminalEvent>.Continuation] = []
    var planned: [PlannedPulse] = []
    lock.withLock {
      lastOutput = now
      for (id, subscriber) in subscribers {
        switch subscriber.interest {
        case .everything:
          readers.append((id, subscriber.continuation))
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
    for reader in readers {
      yield(.output(bytes), to: reader)
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
    for reader in readers(where: { $0 == .everything }) {
      yield(.historyTruncated(droppedByteCount: byteCount), to: reader)
    }
  }

  func stateChanged(_ state: TerminalProcessState) {
    for reader in readers(where: { _ in true }) {
      yield(.stateChanged(state), to: reader)
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

  private typealias Reader = (id: UUID, continuation: AsyncStream<TerminalEvent>.Continuation)

  private func readers(where reads: (TerminalEventInterest) -> Bool) -> [Reader] {
    lock.withLock {
      subscribers.filter { reads($0.value.interest) }.map { ($0.key, $0.value.continuation) }
    }
  }

  /// Called by the session's actor only, one event at a time: the loss a subscriber is owed is
  /// read and written back around the stream's writes without anybody else touching it.
  private func yield(_ event: TerminalEvent, to reader: Reader) {
    var lost = lock.withLock {
      defer { subscribers[reader.id]?.unannouncedLoss = 0 }
      return subscribers[reader.id]?.unannouncedLoss ?? 0
    }
    // The subscriber fell far enough behind that its oldest event was evicted. Tell it how much
    // output it lost so it can show the gap rather than silently rendering a corrupt stream: as
    // its own loss, not the history's, since the history still holds those bytes (#248).
    lost += Self.lostBytes(reader.continuation.yield(event))
    guard lost > 0 else { return }
    // The notice takes a place in the full stream too, and evicts the next oldest event. Told at
    // once with a notice of its own, that one would evict another, down the whole stream: what it
    // evicts is told with the next notice instead (#367).
    let evicted = Self.lostBytes(reader.continuation.yield(.outputDropped(byteCount: lost)))
    guard evicted > 0 else { return }
    lock.withLock { subscribers[reader.id]?.unannouncedLoss += evicted }
  }

  /// The output an eviction took from a subscriber. A dropped state change needs no notice: the
  /// current state is always readable from `state()`, and the subscriber re-reads it when the
  /// stream ends.
  private static func lostBytes(_ result: AsyncStream<TerminalEvent>.Continuation.YieldResult)
    -> Int
  {
    guard case .dropped(let discarded) = result else { return 0 }
    switch discarded {
    case .output(let bytes): return bytes.count
    case .outputDropped(let byteCount): return byteCount
    case .stateChanged, .historyTruncated, .outputPulse: return 0
    }
  }
}
