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
  /// The agents that can coordinate: those handed tools and instructions at launch. Read once the
  /// agents are known; until then, none.
  public internal(set) var coordinatingAgents: Set<String> = []
  /// The coordinators whose done children the user asked to see, for this run: otherwise they are
  /// left out of the sidebar, behind a row that counts them.
  var showingDoneChildren: Set<SessionID> = []

  /// What the user's next message to a session says first: coordination turned on (`true`) or off
  /// while its agent runs. Turned back before it is sent, nothing is said.
  @ObservationIgnored var notices: [SessionID: Bool] = [:]
  /// The sessions coordination was turned on for while their agent ran, launched without the
  /// coordinator's instructions: the first answer of a tool gives them.
  @ObservationIgnored var owedRules: Set<SessionID> = []
  /// Whether each running agent was started with the coordination tools, read from its command
  /// line, for the terminal it runs in: an agent started by an earlier build has none until it is
  /// started again.
  var serving: [SessionID: CoordinationServing] = [:]
  @ObservationIgnored var readingServing: Set<SessionID> = []

  @ObservationIgnored var inbox = CoordinationInbox()
  /// Messages a coordinator sent to a child busy with a turn, typed once it is at rest, in order.
  @ObservationIgnored var outbox: [SessionID: [String]] = [:]
  /// The message typed into each session's prompt but not sent (#435): sent before the next one.
  @ObservationIgnored var leftInInput: [SessionID: LeftMessage] = [:]
  /// Sessions a message is being typed into: one at a time each, never two interleaved.
  @ObservationIgnored var typing: Set<SessionID> = []
  /// Children being created and started, per coordinator: counted against the limit before they
  /// run, so that two creations at once cannot both take the last place.
  @ObservationIgnored var startingChildren: [SessionID: Int] = [:]
  /// The folders of children being created or started, standardized, with the child's name: held
  /// until they run, so that two of them cannot both take one folder.
  @ObservationIgnored var startingFolders: [String: String] = [:]
  /// The writes to the store, one after the other: a wake-up taken away is never put back by an
  /// older write that lands after it.
  @ObservationIgnored private var writes: Task<Void, Never>?
  @ObservationIgnored var wakes: [SessionID: CoordinationWake] = [:]
  /// Runs while something waits to be told: an event, or a wake-up.
  @ObservationIgnored var ticker: Task<Void, Never>?
  /// Whether the ticker sleeps until a wake-up rather than for a second: something new to type
  /// wakes it.
  @ObservationIgnored var tickerSleepsLong = false
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
    if let count = traces[child]?.count, count > CoordinationLimits.traceEntries {
      traces[child]?.removeFirst(count - CoordinationLimits.traceEntries)
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
    let recorded = traces[child]?.count ?? 0
    let stored = await store.trace(of: child)
    // What was recorded while the store was read is not in it: kept after it.
    let since = (traces[child] ?? []).dropFirst(recorded)
    let merged = Array((stored + since).suffix(CoordinationLimits.traceEntries))
    if !merged.isEmpty { traces[child] = merged }
  }
}

/// Whether the agent of one terminal was started with the coordination tools (#352).
struct CoordinationServing: Equatable {
  let terminal: ObjectIdentifier
  let isServed: Bool
}

/// The limit for a workspace assembled without the user defaults.
@MainActor
public final class InMemoryCoordinationPreferences: CoordinationPreferences {
  public var maximumRunningChildren: Int

  public init(maximumRunningChildren: Int = CoordinationLimits.defaultRunningChildren) {
    self.maximumRunningChildren = maximumRunningChildren
  }
}

/// A coordinator's message an agent at rest did not take, still in its prompt (#435).
struct LeftMessage {
  let text: String
  let since: ContinuousClock.Instant
  /// How long Return is given again to it: past that, the prompt is the user's.
  static let lifetime = Duration.seconds(600)
}
