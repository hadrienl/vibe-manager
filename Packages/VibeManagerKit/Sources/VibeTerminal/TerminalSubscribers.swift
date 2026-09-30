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
/// Held inside the session's actor. The pulses it plans are handed back to the actor, which alone
/// can wait for them.
struct TerminalSubscribers {
  private struct Subscriber {
    let continuation: AsyncStream<TerminalEvent>.Continuation
    let interest: TerminalEventInterest
    var gate: PulseGate?
  }

  /// A pulse a subscriber is owed at `deadline`, for the actor to deliver.
  struct PlannedPulse {
    let subscriberID: UUID
    let deadline: ContinuousClock.Instant
  }

  // A subscriber that stops draining its stream must not grow the application's memory without
  // bound. Each queued event holds at most one coalescing window of output, so this caps a stalled
  // subscriber at a few seconds of backlog; beyond that the oldest output is dropped and the gap is
  // reported, exactly as the bounded history does.
  private static let bufferLimit = 512

  private var subscribers: [UUID: Subscriber] = [:]
  /// When the process last wrote something.
  private(set) var lastOutputAt: ContinuousClock.Instant?

  var count: Int { subscribers.count }

  /// What each subscriber reads, for the tests that check nobody reads more than it needs.
  var interests: [TerminalEventInterest] { subscribers.values.map(\.interest) }

  /// A new stream for `interest`, already finished when the session has ended. The subscriber is
  /// removed through `onRemove` when its reader lets go of the stream.
  mutating func add(
    _ interest: TerminalEventInterest,
    hasEnded: Bool,
    onRemove: @escaping @Sendable (UUID) -> Void
  ) -> AsyncStream<TerminalEvent> {
    let (stream, continuation) = AsyncStream<TerminalEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(Self.bufferLimit))
    guard !hasEnded else {
      continuation.finish()
      return stream
    }
    let id = UUID()
    var gate: PulseGate?
    if case .pulses(let interval) = interest { gate = PulseGate(interval: interval) }
    subscribers[id] = Subscriber(continuation: continuation, interest: interest, gate: gate)
    continuation.onTermination = { _ in onRemove(id) }
    return stream
  }

  mutating func remove(_ id: UUID) {
    subscribers[id] = nil
  }

  /// Hands a block of output, and the bytes the history dropped for it, to whoever reads them.
  /// Returns the pulses planned for later, for the actor to deliver.
  mutating func output(
    _ bytes: [UInt8],
    historyDropped dropped: Int,
    at now: ContinuousClock.Instant = .now
  ) -> [PlannedPulse] {
    lastOutputAt = now
    var planned: [PlannedPulse] = []
    for (id, subscriber) in subscribers {
      switch subscriber.interest {
      case .everything:
        yield(.output(bytes), to: subscriber.continuation)
        if dropped > 0 {
          yield(.historyTruncated(droppedByteCount: dropped), to: subscriber.continuation)
        }
      case .state:
        continue
      case .pulses:
        guard var gate = subscriber.gate else { continue }
        switch gate.output(at: now) {
        case .emit:
          subscriber.continuation.yield(.outputPulse)
        case .schedule(let deadline):
          planned.append(PlannedPulse(subscriberID: id, deadline: deadline))
        case .covered:
          break
        }
        subscribers[id]?.gate = gate
      }
    }
    return planned
  }

  /// A planned pulse is due.
  mutating func deliverPulse(to id: UUID, at now: ContinuousClock.Instant = .now) {
    guard let subscriber = subscribers[id] else { return }
    subscribers[id]?.gate?.scheduledPulseFired(at: now)
    subscriber.continuation.yield(.outputPulse)
  }

  /// Bytes lost before they reached the history — trimmed from another buffer on their way here.
  func truncated(_ byteCount: Int) {
    for subscriber in subscribers.values where subscriber.interest == .everything {
      yield(.historyTruncated(droppedByteCount: byteCount), to: subscriber.continuation)
    }
  }

  func stateChanged(_ state: TerminalProcessState) {
    for subscriber in subscribers.values {
      yield(.stateChanged(state), to: subscriber.continuation)
    }
  }

  /// The session ended: every stream ends with it.
  mutating func finishAll() {
    for subscriber in subscribers.values {
      subscriber.continuation.finish()
    }
    subscribers.removeAll()
  }

  private func yield(
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
