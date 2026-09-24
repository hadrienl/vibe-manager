import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

public typealias SessionUsage = UsageOverview.Session

/// The usage figures the interface shows: the section of a session and the Usage window.
///
/// Transcripts are read only while one of them is on screen — the sessions shown, or all of them
/// for the window — every thirty seconds, and never on the main thread: a transcript can weigh
/// tens of megabytes on its first reading.
@MainActor
@Observable
public final class UsageModel {
  public var period: UsagePeriod = .last7Days {
    didSet { if period != oldValue { scheduleRecompute() } }
  }
  public var grouping: UsageGrouping = .session {
    didSet { if grouping != oldValue { scheduleRecompute() } }
  }
  public private(set) var report = UsageReport()
  /// The whole usage of each session shown in the inspector.
  public private(set) var sessionUsage: [SessionID: SessionUsage] = [:]
  public private(set) var isReading = false
  public private(set) var isTrackingEnabled = true
  /// When the first run was recorded: running time and runs start there, tokens do not.
  public private(set) var runsRecordedSince: Date?
  public private(set) var trackingOffSince: Date?
  /// The providers whose CLI writes usage the application can read; `nil` until the registry
  /// has answered, when no agent is said not to report any.
  public var reportingProviderIDs: Set<String>?

  private let service: UsageService
  private var sessions: () -> [WorkSession] = { [] }
  /// How many views show every session (the window), and how many show each one.
  private var everythingWatchers = 0
  private var sessionWatchers: [SessionID: Int] = [:]
  private var watchTask: Task<Void, Never>?
  private var recomputeTask: Task<Void, Never>?
  private var sleepObserver: SleepObserver?
  private let refreshInterval: Duration

  public init(service: UsageService, refreshInterval: Duration = .seconds(30)) {
    self.service = service
    self.refreshInterval = refreshInterval
    sleepObserver = SleepObserver(recorder: service.recorder)
  }

  /// Where the sessions come from: the workspace's own list, archived ones included.
  public func connect(sessions: @escaping () -> [WorkSession]) {
    self.sessions = sessions
  }

  /// Settles what the previous run of the application left open, once the terminal host has
  /// said which agents are still running. A copy that only reads the data writes nothing.
  public func settleLaunch(running: Set<SessionID>, sessions: [WorkSession], readOnly: Bool)
    async
  {
    if readOnly {
      await service.recorder.seal()
    } else {
      var closedAt: [SessionID: Date] = [:]
      for session in sessions {
        if let date = session.closedAt { closedAt[session.id] = date }
      }
      await service.recorder.settleLaunch(running: running, closedAt: closedAt)
    }
    await loadTracking()
  }

  // MARK: - Watching

  /// Called when a view that shows usage appears — one session's, or every session's when
  /// `session` is `nil` — and balanced by `stopWatching` with the same argument.
  public func startWatching(_ session: SessionID? = nil) {
    if let session {
      sessionWatchers[session, default: 0] += 1
    } else {
      everythingWatchers += 1
    }
    if watchTask == nil {
      let interval = refreshInterval
      watchTask = Task { [weak self] in
        while !Task.isCancelled {
          await self?.refresh()
          try? await Task.sleep(for: interval)
        }
      }
    } else {
      // Something new is on screen: it is read now rather than at the next tick.
      Task { await refresh() }
    }
  }

  public func stopWatching(_ session: SessionID? = nil) {
    if let session {
      let count = (sessionWatchers[session] ?? 0) - 1
      sessionWatchers[session] = count > 0 ? count : nil
    } else {
      everythingWatchers = max(everythingWatchers - 1, 0)
    }
    guard everythingWatchers == 0, sessionWatchers.isEmpty else { return }
    watchTask?.cancel()
    watchTask = nil
  }

  /// The sessions whose transcripts are worth reading now.
  private var watchedSessions: [WorkSession] {
    let all = sessions()
    guard everythingWatchers == 0 else { return all }
    return all.filter { sessionWatchers[$0.id] != nil }
  }

  /// Reads the transcripts again, then the figures.
  public func refresh() async {
    guard !isReading else { return }
    isReading = true
    await service.refreshTokens(for: watchedSessions)
    isReading = false
    await recompute()
  }

  /// A change of period or grouping replaces the computation under way, so an earlier one that
  /// finishes last cannot put its figures back on screen.
  private func scheduleRecompute() {
    recomputeTask?.cancel()
    recomputeTask = Task { [weak self] in await self?.recompute() }
  }

  private func recompute() async {
    await loadTracking()
    let period = period
    let grouping = grouping
    let overview = await service.overview(
      period: period, grouping: grouping, sessions: Array(sessionWatchers.keys))
    guard !Task.isCancelled, period == self.period, grouping == self.grouping else { return }
    report = overview.report
    sessionUsage = overview.sessions
    runsRecordedSince = overview.runsRecordedSince
  }

  private func loadTracking() async {
    let intervals = await service.trackingIntervals()
    isTrackingEnabled = intervals.isTracking
    trackingOffSince = isTrackingEnabled ? nil : intervals.last?.to
  }

  // MARK: - Settings

  public func setTracking(_ enabled: Bool) async {
    await service.setTracking(enabled)
    await loadTracking()
    if enabled { await refresh() } else { await recompute() }
  }

  public func clear() async {
    await service.clear()
    await refresh()
  }

  // MARK: - What a figure means

  /// Why a session shows no tokens, when it shows none. `nil` when it has some, or when nothing
  /// has been read for it yet.
  public func tokenUnavailability(for session: WorkSession) -> UsageUnavailability? {
    guard let usage = sessionUsage[session.id] else { return nil }
    if usage.total.hasReportedTokens { return nil }
    let providers = Set(
      session.conversations.map(\.providerID) + [session.agent?.providerID].compactMap { $0 })
    if let reporting = reportingProviderIDs, !providers.isEmpty,
      providers.isDisjoint(with: reporting)
    {
      return .notReportedByAgent
    }
    if !isTrackingEnabled { return .trackingOff }
    return .noTranscript
  }
}

/// Tells the recorder when the Mac sleeps and wakes: the time between is not running time.
private final class SleepObserver: @unchecked Sendable {
  private var tokens: [NSObjectProtocol] = []

  init(recorder: UsageRecorder) {
    let center = NSWorkspace.shared.notificationCenter
    tokens.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
        _ in Task { await recorder.systemWillSleep() }
      })
    tokens.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
        _ in Task { await recorder.systemDidWake() }
      })
  }

  deinit {
    for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
  }
}
