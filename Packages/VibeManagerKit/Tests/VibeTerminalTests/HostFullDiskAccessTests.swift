import Darwin
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

// #76: the host says whether it has Full Disk Access, since every agent it runs inherits its
// answer, and it can be let go — only ever when no agent runs there — for a host born with it.

@Suite("The host and Full Disk Access, in process", .timeLimit(.minutes(1)))
struct HostFullDiskAccessTests {
  @Test("The host says whether it has the access, from its own probe")
  func hostReportsItsAccess() async throws {
    let host = try InProcessTerminalHost(fullDiskAccess: FixedProbe(.granted))
    let supervisor = host.supervisor()
    let go = GoFile()
    _ = try await supervisor.start(TerminalTestSupport.spec(script: go.script), for: SessionID())

    let access = await supervisor.agentRunnerAccess()

    #expect(access == AgentRunnerAccess(runner: .host, hostStatus: .granted, runningAgents: 1))
    go.release()
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A host that cannot say is not taken to have the access")
  func silentHostIsUnknown() async throws {
    let host = try InProcessTerminalHost(fullDiskAccess: nil)
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: "exit 0"), for: SessionID())
    #expect(await Transcript.follow(session).waitForEnd())

    let access = await supervisor.agentRunnerAccess()

    #expect(access.runner == .host)
    #expect(access.hostStatus == nil)
    #expect(access.runningAgents == 0)
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("While another copy holds the host, the application answers for the agents")
  func heldHostLeavesTheApplicationRunning() async throws {
    let host = try InProcessTerminalHost(fullDiskAccess: FixedProbe(.granted))
    let first = host.supervisor()
    let go = GoFile()
    _ = try await first.start(TerminalTestSupport.spec(script: go.script), for: SessionID())
    await first.relinquish(keepRunning: true)
    let other = host.supervisor()
    guard case .connected = await other.reconnect() else {
      Issue.record("The host was not found again")
      return
    }
    let supervisor = host.supervisor()
    guard case .unavailable = await supervisor.reconnect() else {
      Issue.record("A second client was served")
      return
    }

    // Every terminal of this run starts in the application until the kept agents are taken back:
    // it is the application's access that counts, not the one a host born now would get.
    #expect(await supervisor.agentRunnerAccess() == AgentRunnerAccess(runner: .application))

    go.release()
    await other.relinquish(keepRunning: false)
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("An idle host is let go at once, without its grace period")
  func idleHostIsRetired() async throws {
    let host = try InProcessTerminalHost(
      idleGracePeriod: .seconds(60), fullDiskAccess: FixedProbe(.notGranted))
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: "printf 'last words'; exit 0"), for: SessionID())
    let transcript = await Transcript.follow(session)
    #expect(await transcript.waitForEnd())

    #expect(await supervisor.restartHostWhenIdle() == .restarted)

    #expect(await eventually { host.becameIdle })
    #expect(await supervisor.hostIdentity() == nil)
    // What the pane shows of the session that ended is still there.
    #expect(String(decoding: await session.history().bytes, as: UTF8.self).contains("last words"))
    await host.shutDown()
  }

  @Test("A busy host is never stopped: it goes once its last agent has ended")
  func busyHostWaitsForItsLastAgent() async throws {
    let host = try InProcessTerminalHost(
      idleGracePeriod: .seconds(60), fullDiskAccess: FixedProbe(.notGranted))
    let supervisor = host.supervisor()
    let go = GoFile()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: go.script), for: SessionID())
    let transcript = await Transcript.follow(session)

    #expect(await supervisor.restartHostWhenIdle() == .armed)
    #expect(await supervisor.isHostRestartArmed())
    try await Task.sleep(for: .milliseconds(300))
    #expect(!host.becameIdle)
    #expect(await session.state().isFinished == false)

    go.release()
    #expect(await transcript.waitForEnd())
    #expect(await eventually { host.becameIdle })
    #expect(await supervisor.isHostRestartArmed() == false)
    await host.shutDown()
  }

  @Test("A restart called off leaves the host alone")
  func cancelledRestartLeavesTheHost() async throws {
    let host = try InProcessTerminalHost(idleGracePeriod: .seconds(60))
    let supervisor = host.supervisor()
    let go = GoFile()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: go.script), for: SessionID())
    let transcript = await Transcript.follow(session)
    #expect(await supervisor.restartHostWhenIdle() == .armed)

    await supervisor.cancelHostRestart()
    go.release()
    #expect(await transcript.waitForEnd())
    try await Task.sleep(for: .milliseconds(300))

    #expect(!host.becameIdle)
    #expect(await supervisor.hostIdentity() != nil)
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }
}

@Suite("The host and Full Disk Access, in a process of its own", .timeLimit(.minutes(2)))
struct HostFullDiskAccessProcessTests {
  @Test("Once the idle host is let go, the next terminal starts a host of its own")
  func nextTerminalReachesANewHost() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmf-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try TerminalHostProcessTests.fixtureURL(),
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)
    let supervisor = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: TerminalHostProcessTests.launchTimeout, replyTimeout: .seconds(30)))

    let first = try await supervisor.start(
      TerminalTestSupport.spec(script: "exit 0"), for: SessionID())
    #expect(await Transcript.follow(first).waitForEnd())
    // No witness beside the socket: this host was born without the access.
    #expect(await supervisor.agentRunnerAccess().hostStatus == .notGranted)
    let before = try #require(await supervisor.hostIdentity())

    #expect(await supervisor.restartHostWhenIdle() == .restarted)
    #expect(await eventually { !isProcessAlive(before.processIdentifier) })
    // Granted in the meantime, as a switch turned on in System Settings.
    FileManager.default.createFile(
      atPath: location.directory.appendingPathComponent("fda-witness").path, contents: nil)
    let second = try await supervisor.start(
      TerminalTestSupport.spec(script: "exit 0"), for: SessionID())
    #expect(second is HostedTerminalSession)
    let after = try #require(await supervisor.hostIdentity())

    #expect(after.processIdentifier != before.processIdentifier)
    #expect(await supervisor.agentRunnerAccess().hostStatus == .granted)
    await supervisor.relinquish(keepRunning: false)
  }

  @Test("A process born now answers for the access, and a binary that cannot is no answer")
  func spawnedProbeAnswers() async throws {
    let witness = NSTemporaryDirectory() + "vibe-fda-witness"
    try? FileManager.default.removeItem(atPath: witness)
    let probe = SpawnedFullDiskAccessProbe(
      executableURL: try TerminalHostProcessTests.fixtureURL(),
      timeout: TerminalHostProcessTests.launchTimeout,
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)

    #expect(await probe.status() == .notGranted)
    FileManager.default.createFile(atPath: witness, contents: nil)
    defer { try? FileManager.default.removeItem(atPath: witness) }
    #expect(await probe.status() == .granted)

    let nowhere = SpawnedFullDiskAccessProbe(
      executableURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(await nowhere.status() == nil)
  }
}

private struct FixedProbe: FullDiskAccessProbe {
  let value: FullDiskAccessStatus

  init(_ value: FullDiskAccessStatus) {
    self.value = value
  }

  func status() async -> FullDiskAccessStatus { value }
}

/// A terminal that runs until the test says it may end.
private final class GoFile: Sendable {
  let path = NSTemporaryDirectory() + "vmf-go-\(UUID().uuidString.prefix(8))"

  var script: String {
    "while [ ! -e '\(path)' ]; do sleep 0.05; done; exit 0"
  }

  func release() {
    FileManager.default.createFile(atPath: path, contents: nil)
  }

  deinit {
    try? FileManager.default.removeItem(atPath: path)
  }
}
