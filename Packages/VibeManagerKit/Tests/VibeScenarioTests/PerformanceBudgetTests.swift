import Darwin
import Foundation
import Testing
import VibeApplication
import VibeComposition
import VibeDomain
import VibeProcess
import VibeTerminal

@testable import VibeUI

extension Tag {
  @Tag static var performance: Self
}

/// The budgets of #19, measured on the composed application. Opt-in — `VIBE_PERFORMANCE=1` —
/// because a shared CI runner turns every figure into noise; they run on the maintainer's Mac and
/// in the release checklist, which pastes their output into the release. `VIBE_PERFORMANCE_MINUTES`
/// stretches the soak test to the ten minutes the checklist asks for.
@MainActor
@Suite(
  "Performance budgets", .serialized, .tags(.performance),
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_PERFORMANCE"] != nil),
  .timeLimit(.minutes(20)))
struct PerformanceBudgetTests {
  private static var soak: Duration {
    let minutes = Double(ProcessInfo.processInfo.environment["VIBE_PERFORMANCE_MINUTES"] ?? "") ?? 2
    return .milliseconds(Int(minutes * 60_000))
  }

  private static func percentile(_ values: [Duration], _ fraction: Double) -> Duration {
    let sorted = values.sorted()
    return sorted[Int(Double(sorted.count - 1) * fraction)]
  }

  /// Three sessions, two of them flooding 2 MB/s in the background, the third visible.
  private func loaded(_ scenario: Scenario) async throws -> (AppEnvironment, SessionID) {
    let environment = try scenario.compose(
      behaviour: ["--hold", "--flood", "2048"], secondary: ["--hold"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")
    _ = try await scenario.create(in: environment, name: "Flood one", folder: folder)
    _ = try await scenario.create(in: environment, name: "Flood two", folder: folder)
    let visible = try await scenario.create(
      in: environment, name: "Visible", provider: "mock-b", folder: folder)
    environment.appModel.select(visible)
    return (environment, visible)
  }

  private func echo(
    _ text: String, in id: SessionID, of environment: AppEnvironment, scenario: Scenario
  ) async throws -> Duration {
    let session = try #require(scenario.pane(id, in: environment)?.session)
    let watch = EchoWatch(session: session, expecting: "echo: \(text)")
    let started = ContinuousClock.now
    await scenario.type("\(text)\r", into: id, in: environment)
    #expect(await watch.arrived(within: .seconds(10)))
    return ContinuousClock.now - started
  }

  @Test("A keystroke's echo: p95 under 150 ms with two sessions flooding (50 ms on a Mac at rest)")
  func echoLatency() async throws {
    let scenario = try Scenario()
    let (environment, visible) = try await loaded(scenario)
    var latencies: [Duration] = []
    for index in 0..<100 {
      latencies.append(
        try await echo("key-\(index)", in: visible, of: environment, scenario: scenario))
    }
    let p50 = Self.percentile(latencies, 0.5)
    let p95 = Self.percentile(latencies, 0.95)
    print("PERF echo p50 \(p50) p95 \(p95)")
    #expect(p95 < .milliseconds(150))
    await scenario.tearDown()
  }

  @Test("Under load: no main-thread hang over 250 ms, and memory within budget and not growing")
  func soakUnderLoad() async throws {
    let scenario = try Scenario()
    let (environment, visible) = try await loaded(scenario)
    let hangs = RecordingDiagnosticLog()
    let detector = MainThreadHangDetector(log: hangs)
    detector.start()
    defer { detector.stop() }

    let half = Self.soak / 2
    var midpoint: Int?
    let started = ContinuousClock.now
    var index = 0
    while ContinuousClock.now - started < Self.soak {
      _ = try await echo("soak-\(index)", in: visible, of: environment, scenario: scenario)
      index += 1
      if midpoint == nil, ContinuousClock.now - started >= half {
        midpoint = ProcessMetrics.physicalFootprint()
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    let application = try #require(ProcessMetrics.physicalFootprint())
    let host = try #require(await environment.terminalSupervisor.hostFootprint())
    let growth = Double(application - (midpoint ?? application)) / Double(midpoint ?? application)

    print(
      "PERF soak \(Self.soak): application \(application / 1_048_576) MiB, host "
        + "\(host / 1_048_576) MiB, growth \(String(format: "%.1f", growth * 100)) %, "
        + "hangs \(hangs.events(named: "perf.mainThreadHang").count)")
    #expect(hangs.events(named: "perf.mainThreadHang").isEmpty)
    #expect(application < 400 * 1_048_576)
    #expect(host < 60 * 1_048_576)
    #expect(growth < 0.05)
    await scenario.tearDown()
  }

  @Test("At rest: three idle sessions cost under 1 % of a core, application and host together")
  func idleCPU() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"], secondary: ["--hold"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")
    for index in 0..<3 {
      _ = try await scenario.create(in: environment, name: "Idle \(index)", folder: folder)
    }
    let host = try #require(await environment.terminalSupervisor.hostIdentity())
    try await Task.sleep(for: .seconds(5))

    let window: Duration = .seconds(
      Int(ProcessInfo.processInfo.environment["VIBE_PERFORMANCE_IDLE_SECONDS"] ?? "") ?? 60)
    let applicationBefore = ProcessMetrics.cpuTime()
    let hostBefore = try #require(ProcessMetrics.cpuTime(of: host.processIdentifier))
    try await Task.sleep(for: window)
    let application = ProcessMetrics.cpuTime() - applicationBefore
    let hosted = try #require(ProcessMetrics.cpuTime(of: host.processIdentifier)) - hostBefore
    let share = (application + hosted) / window

    print(
      "PERF idle CPU \(String(format: "%.2f", share * 100)) % over \(window): application "
        + "\(application), host \(hosted)")
    #expect(share < 0.01)
    await scenario.tearDown()
  }

  @Test("Launching: ten sessions listed within a second, three kept agents taken back within three")
  func launch() async throws {
    let scenario = try Scenario()
    let first = try scenario.compose(behaviour: ["--hold"])
    await first.appModel.load()
    let folder = try scenario.folder("work")
    var kept: [SessionID] = []
    for index in 0..<10 {
      let id = try await scenario.create(in: first, name: "Session \(index)", folder: folder)
      if index < 3 { kept.append(id) } else { await first.appModel.close(id) }
    }
    await first.shutdown(keepingAgentsRunning: true)

    let started = ContinuousClock.now
    let second = try scenario.compose(behaviour: ["--hold"])
    let loading = Task { await second.appModel.load() }
    #expect(await eventually(timeout: .seconds(5)) { second.appModel.sessions.count == 10 })
    let listed = ContinuousClock.now - started
    await loading.value
    var adopted = false
    for _ in 0..<600 {
      var running = 0
      for id in kept where await scenario.processIdentifier(id, in: second) != nil { running += 1 }
      if running == kept.count {
        adopted = true
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    let takenBack = ContinuousClock.now - started

    print("PERF launch: listed in \(listed), agents taken back in \(takenBack)")
    #expect(adopted)
    #expect(listed < .seconds(1))
    #expect(takenBack < .seconds(3))
    await scenario.tearDown()
  }
}
