import Foundation
import VibeApplication
import VibeDomain

@testable import VibeTerminal

enum TerminalTestSupport {
  /// Whether the host a test starts answers for itself to TCC, as the application's does. A test
  /// run inside a sandbox that kills such a child — an agent's command sandbox — sets
  /// `VIBE_TESTS_WITHOUT_DISCLAIM` to run everything else about the host.
  static var disclaimsResponsibility: Bool {
    ProcessInfo.processInfo.environment["VIBE_TESTS_WITHOUT_DISCLAIM"] == nil
  }

  static func spec(
    script: String,
    size: TerminalSize = .default,
    initialInput: String? = nil,
    scrollback: TerminalScrollbackLimits = .default,
    workingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  ) -> TerminalSpec {
    TerminalSpec(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: TerminalEnvironment.make(),
      workingDirectoryURL: workingDirectory,
      initialSize: size,
      initialInput: initialInput,
      scrollback: scrollback
    )
  }

  static func makeSession(
    script: String,
    size: TerminalSize = .default,
    initialInput: String? = nil,
    scrollback: TerminalScrollbackLimits = .default
  ) throws -> PTYTerminalSession {
    try PTYTerminalSession.start(
      id: SessionID(),
      spec: spec(
        script: script,
        size: size,
        initialInput: initialInput,
        scrollback: scrollback
      )
    )
  }
}

struct TerminalOutcome: Sendable {
  var state: TerminalProcessState
  var bytes: [UInt8]

  var text: String {
    String(decoding: bytes, as: UTF8.self)
  }
}

// Collects every event until the session finalizes. A watchdog kills the process so that a
// regression fails the test instead of hanging the suite.
func runToCompletion(
  _ session: PTYTerminalSession,
  timeout: Duration = .seconds(15)
) async -> TerminalOutcome {
  let attachment = await session.attach()
  let watchdog = Task {
    try? await Task.sleep(for: timeout)
    await session.kill()
  }
  defer { watchdog.cancel() }

  var outcome = TerminalOutcome(state: attachment.state, bytes: attachment.history.bytes)
  for await event in attachment.events {
    switch event {
    case .output(let chunk):
      outcome.bytes.append(contentsOf: chunk)
    case .stateChanged(let state):
      outcome.state = state
    case .historyTruncated:
      break
    }
  }
  return outcome
}

actor TerminalObserver {
  private var bytes: [UInt8] = []
  private var lastState: TerminalProcessState
  private var isFinished = false
  private var consumer: Task<Void, Never>?

  init(state: TerminalProcessState) {
    lastState = state
  }

  static func attach(to session: PTYTerminalSession) async -> TerminalObserver {
    let attachment = await session.attach()
    let observer = TerminalObserver(state: attachment.state)
    await observer.consume(attachment.events)
    return observer
  }

  private func consume(_ events: AsyncStream<TerminalEvent>) {
    consumer = Task { [weak self] in
      for await event in events {
        await self?.ingest(event)
      }
      await self?.markFinished()
    }
  }

  private func ingest(_ event: TerminalEvent) {
    switch event {
    case .output(let chunk):
      bytes.append(contentsOf: chunk)
    case .stateChanged(let state):
      lastState = state
    case .historyTruncated:
      break
    }
  }

  private func markFinished() {
    isFinished = true
  }

  var text: String {
    String(decoding: bytes, as: UTF8.self)
  }

  var state: TerminalProcessState {
    lastState
  }

  func waitForText(
    _ needle: String,
    occurrences: Int = 1,
    timeout: Duration = .seconds(10)
  ) async -> Bool {
    var waited = Duration.zero
    while waited < timeout {
      if text.components(separatedBy: needle).count > occurrences { return true }
      waited += await sleepCountingRunTime()
    }
    return text.components(separatedBy: needle).count > occurrences
  }

  func waitForCompletion(timeout: Duration = .seconds(10)) async -> Bool {
    var waited = Duration.zero
    while waited < timeout {
      if isFinished { return true }
      waited += await sleepCountingRunTime()
    }
    return isFinished
  }

  func cancel() {
    consumer?.cancel()
  }
}

/// Sleeps a poll's interval, and says how much of the wait to count: a runner that stalled the
/// process wakes it much later than asked, and that time is not the condition's.
func sleepCountingRunTime(_ interval: Duration = .milliseconds(20)) async -> Duration {
  let asleep = ContinuousClock.now
  try? await Task.sleep(for: interval)
  return min(ContinuousClock.now - asleep, interval * 5)
}

func isProcessAlive(_ processIdentifier: pid_t) -> Bool {
  kill(processIdentifier, 0) == 0 || errno == EPERM
}
