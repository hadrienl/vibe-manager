import Dispatch
import Foundation
import VibeApplication
import VibeProcess
import VibeTerminal
import VibeUI

/// Notices when the main thread stops answering.
///
/// A utility timer asks the main queue to answer every `interval`; an answer that took longer
/// than `threshold` is logged as `perf.mainThreadHang`, with how long it took. It measures what
/// the user feels — a click or a keystroke waiting on the main thread — and nothing else. Only one
/// question is ever outstanding, so a hang of ten seconds is one event, not a hundred.
public final class MainThreadHangDetector: @unchecked Sendable {
  public static let defaultThreshold: Duration = .milliseconds(250)

  private let log: any DiagnosticLog
  private let interval: Duration
  private let threshold: Duration
  private let queue = DispatchQueue(label: "com.hadrienl.VibeManager.hang-detector", qos: .utility)
  private let lock = NSLock()
  private var askedAt: ContinuousClock.Instant?
  private var timer: (any DispatchSourceTimer)?

  public init(
    log: any DiagnosticLog,
    interval: Duration = .milliseconds(100),
    threshold: Duration = MainThreadHangDetector.defaultThreshold
  ) {
    self.log = log
    self.interval = interval
    self.threshold = threshold
  }

  public func start() {
    lock.withLock {
      guard timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      let milliseconds = Int(interval / .milliseconds(1))
      timer.schedule(
        deadline: .now() + .milliseconds(milliseconds), repeating: .milliseconds(milliseconds),
        leeway: .milliseconds(max(1, milliseconds / 10)))
      timer.setEventHandler { [weak self] in self?.ask() }
      timer.resume()
      self.timer = timer
    }
  }

  public func stop() {
    lock.withLock {
      timer?.cancel()
      timer = nil
    }
  }

  private func ask() {
    let shouldAsk = lock.withLock {
      guard askedAt == nil else { return false }
      askedAt = .now
      return true
    }
    guard shouldAsk else { return }
    DispatchQueue.main.async { [weak self] in self?.answered() }
  }

  private func answered() {
    guard
      let asked = lock.withLock({ () -> ContinuousClock.Instant? in
        defer { askedAt = nil }
        return askedAt
      })
    else { return }
    let waited = ContinuousClock.now - asked
    guard waited > threshold else { return }
    log.record(.perf, .notice, "perf.mainThreadHang", ["duration": .duration(waited)])
  }
}

/// Notes what the application and its terminal host weigh: when the number of running sessions
/// changes, and every ten minutes while one runs. Rare enough to cost nothing, often enough for a
/// leak to show in an export.
@MainActor
public final class MemorySampler {
  public static let period: Duration = .seconds(10 * 60)

  private let diagnostics: Diagnostics
  private let launcher: SessionLauncher
  private let supervisor: HostedTerminalSupervisor
  private let check: Duration
  private let period: Duration
  private var task: Task<Void, Never>?

  public init(
    diagnostics: Diagnostics,
    launcher: SessionLauncher,
    supervisor: HostedTerminalSupervisor,
    check: Duration = .seconds(10),
    period: Duration = MemorySampler.period
  ) {
    self.diagnostics = diagnostics
    self.launcher = launcher
    self.supervisor = supervisor
    self.check = check
    self.period = period
  }

  public func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      var lastCount = -1
      var lastSample = ContinuousClock.now
      while !Task.isCancelled {
        guard let self else { return }
        let count = self.launcher.hostedRunningCount + self.launcher.inProcessRunningCount
        if count != lastCount || (count > 0 && ContinuousClock.now - lastSample >= self.period) {
          await self.sample(sessions: count)
          lastCount = count
          lastSample = .now
        }
        try? await Task.sleep(for: self.check)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  /// One sample now.
  public func sample(sessions: Int) async {
    var fields: [(name: StaticString, value: DiagnosticValue)] = [("sessions", .count(sessions))]
    if let application = ProcessMetrics.physicalFootprint() {
      fields.append(("application", .bytes(application)))
    }
    if let host = await supervisor.hostFootprint() {
      fields.append(("host", .bytes(host)))
    }
    diagnostics.log.record(DiagnosticEvent(.perf, .info, "perf.memory", fields: fields))
  }
}
