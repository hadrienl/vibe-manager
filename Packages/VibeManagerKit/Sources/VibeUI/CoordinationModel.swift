import Foundation
import Observation
import VibeApplication
import VibeDomain

/// What coordination keeps between two calls of a coordinator's tools (#352): the limit the user
/// set, the coordinators calling the user, the traces of what they did to their children, what
/// waits to be told to them, and the wake-ups they asked for.
@MainActor
@Observable
public final class CoordinationModel {
  @ObservationIgnored private let store: (any CoordinationStore)?
  @ObservationIgnored private let preferences: any CoordinationPreferences
  @ObservationIgnored let now: @MainActor () -> Date

  /// How many children of one coordinator may run at once: Settings › Coordination.
  public var maximumRunningChildren: Int {
    didSet {
      let bounded = min(
        max(maximumRunningChildren, CoordinationLimits.runningChildren.lowerBound),
        CoordinationLimits.runningChildren.upperBound)
      if bounded != maximumRunningChildren {
        maximumRunningChildren = bounded
        return
      }
      preferences.maximumRunningChildren = bounded
    }
  }

  /// The coordinators that called the user, with what they said, until the user opens them.
  public internal(set) var calls: [SessionID: String] = [:]
  /// What coordinators did to each child, as read or written in this run.
  public internal(set) var traces: [SessionID: [CoordinationTraceEntry]] = [:]

  @ObservationIgnored var inbox = CoordinationInbox()
  /// Messages a coordinator sent to a child busy with a turn, typed once it is at rest, in order.
  @ObservationIgnored var outbox: [SessionID: [String]] = [:]
  /// Sessions a message is being typed into: one at a time each, never two interleaved.
  @ObservationIgnored var typing: Set<SessionID> = []
  /// Children being created and started, per coordinator: counted against the limit before they
  /// run, so that two creations at once cannot both take the last place.
  @ObservationIgnored var startingChildren: [SessionID: Int] = [:]
  /// The writes to the store, one after the other: a wake-up taken away is never put back by an
  /// older write that lands after it.
  @ObservationIgnored private var writes: Task<Void, Never>?
  @ObservationIgnored var wakes: [SessionID: CoordinationWake] = [:]
  /// Runs while something waits to be told: an event, or a wake-up.
  @ObservationIgnored var ticker: Task<Void, Never>?
  /// The traces already read from the store.
  @ObservationIgnored private var loadedTraces: Set<SessionID> = []

  public init(
    store: (any CoordinationStore)? = nil,
    preferences: any CoordinationPreferences = InMemoryCoordinationPreferences(),
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.store = store
    self.preferences = preferences
    self.now = now
    maximumRunningChildren = preferences.maximumRunningChildren
  }

  /// Reads the wake-ups kept from the previous run: one past due is told at once.
  func load() async {
    guard let store else { return }
    wakes = await store.wakes()
  }

  func setWake(_ wake: CoordinationWake?, for coordinator: SessionID) {
    wakes[coordinator] = wake
    write { await $0.setWake(wake, for: coordinator) }
  }

  func record(_ entry: CoordinationTraceEntry, for child: SessionID) {
    traces[child, default: []].append(entry)
    if let count = traces[child]?.count, count > FileCoordinationTraceLimit.value {
      traces[child]?.removeFirst(count - FileCoordinationTraceLimit.value)
    }
    write { await $0.append(entry, to: child) }
  }

  private func write(_ operation: @escaping @Sendable (any CoordinationStore) async -> Void) {
    guard let store else { return }
    let previous = writes
    writes = Task {
      await previous?.value
      await operation(store)
    }
  }

  /// Reads a child's trace from the store, once.
  func loadTrace(of child: SessionID) async {
    guard let store, loadedTraces.insert(child).inserted else { return }
    // After the writes under way, so that what was recorded meanwhile is in what is read.
    await writes?.value
    let stored = await store.trace(of: child)
    if !stored.isEmpty { traces[child] = stored }
  }
}

/// How many entries a child's trace keeps, as the store keeps them.
enum FileCoordinationTraceLimit {
  static let value = 200
}

/// The limit for a workspace assembled without the user defaults.
@MainActor
public final class InMemoryCoordinationPreferences: CoordinationPreferences {
  public var maximumRunningChildren: Int

  public init(maximumRunningChildren: Int = CoordinationLimits.defaultRunningChildren) {
    self.maximumRunningChildren = maximumRunningChildren
  }
}
