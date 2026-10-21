import Foundation
import VibeDomain

/// The active sessions of this Mac, as the mobile companion shows them (#347): read only, a title,
/// an agent and where it stands. Nothing the phone could act on.
public struct CompanionSnapshot: Hashable, Sendable {
  /// The agent's state in three words, read from `AgentActivity` and never recomputed.
  public enum State: String, Hashable, Sendable {
    case waiting
    case working
    case needsAttention
  }

  public struct Session: Hashable, Sendable {
    public let id: SessionID
    public let title: String
    public let agent: String
    public let state: State

    public init(id: SessionID, title: String, agent: String, state: State) {
      self.id = id
      self.title = title
      self.agent = agent
      self.state = state
    }
  }

  public var sessions: [Session]

  public init(sessions: [Session]) {
    self.sessions = sessions
  }

  /// The sessions whose agent runs — open, neither closed nor archived — in the sidebar's order. A
  /// session planned or finished is not published. An agent that never said what it does is
  /// waiting, which is what its terminal shows.
  public static func make(
    sessions: [WorkSession],
    activity: (SessionID) -> AgentActivityState?,
    agentName: (String) -> String
  ) -> CompanionSnapshot {
    let active = sessions.filter { $0.status == .active }.sorted { $0.rank < $1.rank }
    return CompanionSnapshot(
      sessions: active.map { session in
        Session(
          id: session.id, title: session.name,
          agent: session.agent.map { agentName($0.providerID) } ?? "",
          state: State(activity(session.id)?.activity))
      })
  }
}

extension CompanionSnapshot.State {
  init(_ activity: AgentActivity?) {
    switch activity {
    case .working: self = .working
    case .awaitingUser: self = .needsAttention
    case .idle, nil: self = .waiting
    }
  }
}

/// A test the phone sent, as the companion agent found it in iCloud.
public struct CompanionTest: Hashable, Sendable {
  public let nonce: String
  public let deviceName: String
  /// The phone's clock.
  public let sentAt: Date

  public init(nonce: String, deviceName: String, sentAt: Date) {
    self.nonce = nonce
    self.deviceName = deviceName
    self.sentAt = sentAt
  }
}

/// The mobile companion, as the application sees it: something sessions are handed to, and tests
/// acknowledged through. No CloudKit behind this port: the companion agent holds it (ADR 0021).
public protocol CompanionPublishing: Sendable {
  func publish(_ snapshot: CompanionSnapshot) async
  /// Tells the phone the Mac has its test, as soon as it does.
  func acknowledge(_ test: CompanionTest, receivedAt: Date) async
}

/// What shows the user a test received: an alert in the application, a fake in the tests, which
/// never put an alert on screen.
@MainActor
public protocol CompanionTestAlerting: AnyObject {
  /// Returns at once: the alert waits for its OK on its own.
  func present(_ test: CompanionTest, receivedAt: Date)
}

/// Hands the companion the active sessions whenever they change (#347).
///
/// Every write the companion agent makes is a silent push to the phone, and iOS delays or drops
/// them past a few an hour: a burst of changes — an agent that works, asks, works again — leaves
/// as one snapshot, the last, after `coalescing`; a snapshot that ends where the last one sent was
/// is not sent at all.
@MainActor
public final class PublishCompanionSnapshot {
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  private let publisher: any CompanionPublishing
  private let coalescing: Duration
  private let sleep: Sleep
  private var published: CompanionSnapshot?
  private var pending: CompanionSnapshot?
  private var flush: Task<Void, Never>?

  public init(
    publisher: any CompanionPublishing,
    coalescing: Duration = .seconds(5),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.publisher = publisher
    self.coalescing = coalescing
    self.sleep = sleep
  }

  /// Whether a snapshot waits for the end of its burst.
  var isWaiting: Bool {
    flush != nil
  }

  public func update(_ snapshot: CompanionSnapshot) {
    guard snapshot != (pending ?? published) else { return }
    pending = snapshot
    guard flush == nil else { return }
    let delay = coalescing
    let sleep = sleep
    flush = Task { [weak self] in
      try? await sleep(delay)
      await self?.publishPending()
    }
  }

  private func publishPending() async {
    flush = nil
    guard let snapshot = pending else { return }
    pending = nil
    guard snapshot != published else { return }
    published = snapshot
    await publisher.publish(snapshot)
  }
}

/// A test from the phone reached the application (#347): acknowledged at once, then shown. The
/// acknowledgement measures the synchronisation, not the user, so it never waits for the OK.
@MainActor
public struct ReceiveCompanionTest {
  private let publisher: any CompanionPublishing
  private let alerts: any CompanionTestAlerting
  private let clock: @Sendable () -> Date

  public init(
    publisher: any CompanionPublishing, alerts: any CompanionTestAlerting,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.publisher = publisher
    self.alerts = alerts
    self.clock = clock
  }

  public func callAsFunction(_ test: CompanionTest) async {
    let receivedAt = clock()
    await publisher.acknowledge(test, receivedAt: receivedAt)
    alerts.present(test, receivedAt: receivedAt)
  }
}
