import Foundation
import Testing
import VibeApplication
import VibeComposition

@testable import VibeTerminal

@MainActor
@Suite("Performance monitoring")
struct PerformanceMonitorTests {
  @Test("A main thread held longer than the threshold is noted once, with how long it was held")
  func noticesHangs() async throws {
    let log = RecordingDiagnosticLog()
    let detector = MainThreadHangDetector(
      log: log, interval: .milliseconds(20), threshold: .milliseconds(150))
    detector.start()
    defer { detector.stop() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.events(named: "perf.mainThreadHang").isEmpty)

    // Held, the way a synchronous layout or a blocking read would hold it.
    usleep(400_000)

    #expect(
      await eventually(timeout: .seconds(5)) { !log.events(named: "perf.mainThreadHang").isEmpty })
    let hangs = log.events(named: "perf.mainThreadHang")
    #expect(hangs.count == 1)
    guard case .duration(let held) = hangs.first?.value(of: "duration") else {
      Issue.record("No duration")
      return
    }
    #expect(held >= .milliseconds(300))
  }

  @Test("A host that speaks stats reports its footprint; the application asks nothing of others")
  func hostFootprint() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vms-\(UUID().uuidString.prefix(8))", isDirectory: true))
    try location.prepare()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let listener = try UnixSocket.listen(at: location.socketPath)
    let server = TerminalHostServer(
      configuration: TerminalHostServer.Configuration(verifier: SameUserPeerVerifier()),
      onIdle: {})
    let source = TerminalHost.accept(on: listener, into: server)
    defer { source.cancel() }
    let supervisor = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: nil, verifier: SameUserPeerVerifier(),
        replyTimeout: .seconds(30)))

    #expect(await supervisor.hostFootprint() == nil)
    _ = await supervisor.reconnect()
    let footprint = try #require(await supervisor.hostFootprint())

    #expect(footprint > 1_000_000)
    await supervisor.relinquish(keepRunning: false)
    await server.stopEverything()
  }
}
