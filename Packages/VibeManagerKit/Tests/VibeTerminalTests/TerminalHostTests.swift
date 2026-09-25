import Darwin
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

// The host, the client and the socket between them, for real — only the process is shared: the
// server runs in the test, listening on a socket of its own. The suite that follows spawns it.

private let idleScript = """
  i=0
  while [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  """

/// A host served from inside the test process.
final class InProcessTerminalHost: @unchecked Sendable {
  let location: TerminalHostLocation
  let server: TerminalHostServer
  private let source: any DispatchSourceRead
  private let idle = IdleFlag()

  init(
    idleGracePeriod: Duration = .seconds(60),
    maximumRunningSessions: Int = TerminalHostServer.defaultMaximumRunningSessions
  ) throws {
    location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmh-\(UUID().uuidString.prefix(8))", isDirectory: true))
    try location.prepare()
    let listener = try UnixSocket.listen(at: location.socketPath)
    let idle = idle
    server = TerminalHostServer(
      configuration: TerminalHostServer.Configuration(
        verifier: SameUserPeerVerifier(), idleGracePeriod: idleGracePeriod,
        maximumRunningSessions: maximumRunningSessions),
      onIdle: { idle.set() }
    )
    source = TerminalHost.accept(on: listener, into: server)
  }

  /// Generous replies: on a loaded CI runner a handshake past the default deadline falls back to
  /// a terminal in the test process, and every test about the host would then test nothing.
  func supervisor() -> HostedTerminalSupervisor {
    HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: nil, verifier: SameUserPeerVerifier(),
        replyTimeout: .seconds(30)))
  }

  var becameIdle: Bool { idle.isSet }

  func shutDown() async {
    source.cancel()
    await server.stopEverything()
    try? FileManager.default.removeItem(at: location.directory)
  }
}

final class IdleFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool { lock.withLock { value } }

  func set() { lock.withLock { value = true } }
}

/// Everything a terminal said, from its history on, and how it ended.
actor Transcript {
  private var bytes: [UInt8] = []
  private(set) var state: TerminalProcessState
  private(set) var isFinished = false

  private init(history: [UInt8], state: TerminalProcessState) {
    bytes = history
    self.state = state
  }

  static func follow(_ session: any TerminalSession) async -> Transcript {
    let attachment = await session.attach()
    let transcript = Transcript(history: attachment.history.bytes, state: attachment.state)
    Task {
      for await event in attachment.events {
        await transcript.ingest(event)
      }
      await transcript.finish(await session.state())
    }
    return transcript
  }

  var text: String { String(decoding: bytes, as: UTF8.self) }

  // No deadline of their own: on a busy runner a terminal took more than ten seconds to print a
  // word and end. The time limit of the suites stops a wait that never comes.
  func waitFor(_ needle: String) async -> Bool {
    while !text.contains(needle), !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return text.contains(needle)
  }

  func waitForEnd() async -> Bool {
    while !isFinished, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return isFinished
  }

  private func ingest(_ event: TerminalEvent) {
    switch event {
    case .output(let chunk): bytes.append(contentsOf: chunk)
    case .stateChanged(let state): self.state = state
    case .historyTruncated: break
    }
  }

  private func finish(_ state: TerminalProcessState) {
    self.state = state
    isFinished = true
  }
}

func eventually(
  timeout: Duration = .seconds(10),
  _ condition: () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return await condition()
}

@Suite("The terminal host, in process", .timeLimit(.minutes(1)))
struct TerminalHostTests {
  @Test("A terminal started through the host runs, is read, and reports how it ended")
  func runsThroughTheHost() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()

    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: "printf 'hello from the host'; exit 3"), for: SessionID())
    let transcript = await Transcript.follow(session)

    #expect(session is HostedTerminalSession)
    #expect(await transcript.waitForEnd())
    #expect(await transcript.text.contains("hello from the host"))
    #expect(await session.state() == .exited(code: 3))
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("Keystrokes reach the process, in order")
  func forwardsInput() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()

    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: "read first; read second; echo \"got:$first/$second\""),
      for: SessionID())
    let transcript = await Transcript.follow(session)
    await session.write("one\r")
    await session.write("two\r")

    #expect(await transcript.waitFor("got:one/two"))
    #expect(await transcript.waitForEnd())
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("Output larger than a frame crosses whole, and the connection survives it")
  func largeOutputIsCut() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    // Far above a frame's payload, in bursts the reader coalesces up to 4 MiB.
    let session = try await supervisor.start(
      TerminalTestSupport.spec(
        script: "head -c 3000000 /dev/zero | tr '\\0' 'x'; printf '\\nend-of-output\\n'",
        scrollback: TerminalScrollbackLimits(maximumLineCount: 10, maximumByteCount: 8_000_000)),
      for: SessionID())
    let transcript = await Transcript.follow(session)

    #expect(await transcript.waitFor("end-of-output"))
    #expect(await transcript.waitForEnd())
    #expect(await session.state() == .exited(code: 0))
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A paste larger than a frame does not cost the connection")
  func largeInputIsCut() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: idleScript), for: SessionID())

    // Sent whole, it would exceed what the host accepts in a frame, and the host would read the
    // closed connection as a crash of the application — stopping every agent.
    await session.write([UInt8](repeating: UInt8(ascii: "y"), count: 1_500_000))

    let next = try await supervisor.start(
      TerminalTestSupport.spec(script: "printf still-connected"), for: SessionID())
    #expect(next is HostedTerminalSession)
    #expect(await Transcript.follow(next).waitFor("still-connected"))
    #expect(await session.state().isFinished == false)
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A stop answers only once the last output and the final state have arrived")
  func stopArrivesAfterTheLastOutput() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(
        script:
          "trap 'printf \"parting words\\n\"; exit 0' TERM; printf 'up\\n'; while :; do sleep 0.05; done"
      ),
      for: SessionID())
    let transcript = await Transcript.follow(session)
    #expect(await transcript.waitFor("up"))

    await session.stop(gracePeriod: .seconds(3))

    #expect(await transcript.text.contains("parting words"))
    #expect(await session.state().isFinished)
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("Past its limit, the host refuses a session instead of running out of descriptors")
  func refusesPastTheLimit() async throws {
    let host = try InProcessTerminalHost(maximumRunningSessions: 2)
    let supervisor = host.supervisor()
    let first = try await supervisor.start(
      TerminalTestSupport.spec(script: idleScript), for: SessionID())
    _ = try await supervisor.start(TerminalTestSupport.spec(script: idleScript), for: SessionID())

    await #expect(throws: TerminalError.tooManySessions(limit: 2)) {
      _ = try await supervisor.start(TerminalTestSupport.spec(script: "true"), for: SessionID())
    }

    // A session that ends makes room again.
    await first.stop(gracePeriod: .seconds(3))
    let next = try await supervisor.start(
      TerminalTestSupport.spec(script: "printf room"), for: SessionID())
    #expect(await Transcript.follow(next).waitFor("room"))
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("The host raises its descriptor limit, never above the hard one")
  func raisesDescriptorLimit() {
    var before = rlimit()
    getrlimit(RLIMIT_NOFILE, &before)

    let raised = TerminalHost.raiseDescriptorLimit()

    #expect(raised >= min(before.rlim_max, TerminalHost.descriptorLimit))
    #expect(raised <= before.rlim_max)
    #expect(raised >= before.rlim_cur)
  }

  @Test("A start the host refuses fails with the host's reason")
  func startFailureIsTyped() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    var spec = TerminalTestSupport.spec(script: "true")
    spec.executableURL = URL(fileURLWithPath: "/nowhere/agent")

    await #expect(throws: TerminalError.executableNotFound(path: "/nowhere/agent")) {
      _ = try await supervisor.start(spec, for: SessionID())
    }
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("Left running, a session is found again with its history, and goes on live")
  func reattachesToARunningSession() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    let id = SessionID()
    let session = try await first.start(
      TerminalTestSupport.spec(script: "printf 'before\\n'; read go; printf 'after\\n'"), for: id)
    try #require(session is HostedTerminalSession)
    #expect(await Transcript.follow(session).waitFor("before"))

    await first.relinquish(keepRunning: true)
    let second = host.supervisor()
    guard case .connected(_, let sessions) = await second.reconnect() else {
      Issue.record("The host was not found again")
      return
    }

    #expect(sessions.map(\.id) == [id])
    #expect(sessions.first?.state.isFinished == false)
    let adopted = try #require(await second.session(for: id))
    let transcript = await Transcript.follow(adopted)
    #expect(await transcript.text.contains("before"))
    // Told to go on only now, so that it is still running whatever the machine's pace.
    await adopted.write("go\r")
    #expect(await transcript.waitFor("after"))
    #expect(await transcript.waitForEnd())
    #expect(await adopted.state() == .exited(code: 0))
    await second.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A goodbye queued behind a large write still leaves before the connection closes")
  func goodbyeIsNotCutOff() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    let id = SessionID()
    let session = try await first.start(TerminalTestSupport.spec(script: idleScript), for: id)
    // Megabytes queued ahead of the goodbye: closing as soon as it is queued would drop it, and the
    // host would take the departure for a crash — stopping the agent it was asked to keep.
    await session.write([UInt8](repeating: UInt8(ascii: "z"), count: 3_000_000))

    await first.relinquish(keepRunning: true)

    let second = host.supervisor()
    guard case .connected(_, let sessions) = await second.reconnect() else {
      Issue.record("The host was not found again")
      return
    }
    #expect(sessions.map(\.id) == [id])
    #expect(sessions.first?.state.isFinished == false)
    await second.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A session that ended while nobody was attached keeps its last output until it is read")
  func keepsWhatEndedWhileAway() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    let id = SessionID()
    // Told to end only once its client has left: ending on a timer, it ended before the goodbye on
    // a loaded runner, and the client still attached read it and released it.
    let go = host.location.directory.appendingPathComponent("go").path
    let session = try await first.start(
      TerminalTestSupport.spec(
        script: "while [ ! -e '\(go)' ]; do sleep 0.05; done; printf 'last words\\n'; exit 4"),
      for: id)
    guard case .running(let processIdentifier) = await session.state() else {
      Issue.record("The session did not start")
      return
    }
    await first.relinquish(keepRunning: true)

    #expect(await host.server.sessionCount == 1)
    #expect(FileManager.default.createFile(atPath: go, contents: nil))
    #expect(await eventually { !isProcessAlive(processIdentifier) })
    try await Task.sleep(for: .milliseconds(300))
    let second = host.supervisor()
    guard case .connected(_, let sessions) = await second.reconnect() else {
      Issue.record("The host was not found again")
      return
    }

    #expect(sessions.first?.state == .exited(code: 4))
    #expect(sessions.first?.endedAt != nil)
    let adopted = try #require(await second.session(for: id))
    #expect(await adopted.state() == .exited(code: 4))
    #expect(String(decoding: await adopted.history().bytes, as: UTF8.self).contains("last words"))
    // Read, and so released: the host holds nothing for it any more.
    #expect(await eventually { await host.server.sessionCount == 0 })
    await second.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A client that vanishes without saying goodbye takes its agents with it, children too")
  func abruptDisconnectStopsEverything() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    let childFile = NSTemporaryDirectory() + "vmh-child-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: childFile) }
    let session = try await supervisor.start(
      TerminalTestSupport.spec(
        script: """
          /bin/sh -c 'trap "" HUP TERM; while :; do sleep 1; done' &
          echo $! > '\(childFile)'
          \(idleScript)
          """),
      for: SessionID())
    guard case .running(let processIdentifier) = await session.state() else {
      Issue.record("The session did not start")
      return
    }
    #expect(await eventually { FileManager.default.fileExists(atPath: childFile) })
    let child =
      Int32(
        (try? String(contentsOfFile: childFile, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0

    await supervisor.dropConnection()

    #expect(await eventually { !isProcessAlive(processIdentifier) })
    #expect(await eventually { !isProcessAlive(child) })
    #expect(await eventually { await host.server.sessionCount == 0 })
    await host.shutDown()
  }

  @Test("Saying goodbye without keeping them running stops them too")
  func goodbyeStops() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: idleScript), for: SessionID())
    guard case .running(let processIdentifier) = await session.state() else {
      Issue.record("The session did not start")
      return
    }

    await supervisor.relinquish(keepRunning: false)

    #expect(await eventually { !isProcessAlive(processIdentifier) })
    await host.shutDown()
  }

  @Test("A second client is refused while the first is attached")
  func refusesASecondClient() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    _ = try await first.start(TerminalTestSupport.spec(script: idleScript), for: SessionID())

    let second = host.supervisor()
    guard case .unavailable = await second.reconnect() else {
      Issue.record("A second client was served")
      return
    }
    await first.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("Stepping away from a host leaves its agents running, for the next attempt to find")
  func steppingAwayKeepsTheAgents() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    let id = SessionID()
    let session = try await first.start(TerminalTestSupport.spec(script: idleScript), for: id)
    guard case .running(let processIdentifier) = await session.state() else {
      Issue.record("The session did not start")
      return
    }
    await first.relinquish(keepRunning: true)

    let second = host.supervisor()
    guard case .connected = await second.reconnect() else {
      Issue.record("The host was not found again")
      return
    }
    await second.stepAway()

    let third = host.supervisor()
    guard case .connected(_, let sessions) = await third.reconnect() else {
      Issue.record("The host was not found after stepping away")
      return
    }
    #expect(sessions.map(\.id) == [id])
    #expect(isProcessAlive(processIdentifier))
    await third.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("Until the kept agents are taken back, a new terminal runs in the application")
  func keptAgentsAreNotOverridden() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    let kept = SessionID()
    _ = try await first.start(TerminalTestSupport.spec(script: idleScript), for: kept)
    await first.relinquish(keepRunning: true)
    // Another copy holds the host while this one launches.
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
    await other.stepAway()

    // Connecting for it would make this copy the host's client without the kept agent, and its
    // goodbye would stop an agent nobody had seen again.
    let started = try await supervisor.start(
      TerminalTestSupport.spec(script: "printf local"), for: SessionID())
    #expect(started is PTYTerminalSession)

    guard case .connected(_, let sessions) = await supervisor.reconnect() else {
      Issue.record("Trying again did not find the host")
      return
    }
    #expect(sessions.map(\.id) == [kept])
    await supervisor.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("A terminal started again without its host is the one found and stopped")
  func localRestartIsNotShadowed() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    let id = SessionID()
    let hosted = try await supervisor.start(TerminalTestSupport.spec(script: "exit 0"), for: id)
    #expect(await Transcript.follow(hosted).waitForEnd())
    await host.shutDown()
    #expect(await eventually { await supervisor.hostIdentity() == nil })

    let local = try await supervisor.start(
      TerminalTestSupport.spec(script: idleScript), for: id)
    #expect(local is PTYTerminalSession)
    #expect(await supervisor.session(for: id) is PTYTerminalSession)
    await supervisor.stop(id: id, gracePeriod: .seconds(1))
    #expect(await local.state().isFinished)
  }

  @Test("Reattached, a program is told to draw itself again even at the same size")
  func redrawsAfterReattaching() async throws {
    let host = try InProcessTerminalHost()
    let first = host.supervisor()
    let id = SessionID()
    let session = try await first.start(
      TerminalTestSupport.spec(
        script: "trap 'echo WINCH' WINCH; printf 'ready\\n'; while :; do sleep 0.05; done"),
      for: id)
    #expect(await Transcript.follow(session).waitFor("ready"))
    await first.relinquish(keepRunning: true)

    let second = host.supervisor()
    _ = await second.reconnect()
    let adopted = try #require(await second.session(for: id))
    let transcript = await Transcript.follow(adopted)
    // The size it already has: the kernel raises nothing for that, the redraw does.
    await adopted.resize(to: .default)

    #expect(await transcript.waitFor("WINCH"))
    await second.relinquish(keepRunning: false)
    await host.shutDown()
  }

  @Test("With no session and no client, the host ends itself")
  func endsWhenIdle() async throws {
    let host = try InProcessTerminalHost(idleGracePeriod: .milliseconds(200))
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: "exit 0"), for: SessionID())
    #expect(await Transcript.follow(session).waitForEnd())
    #expect(!host.becameIdle)

    await supervisor.relinquish(keepRunning: false)

    #expect(await eventually { host.becameIdle })
    await host.shutDown()
  }

  @Test("Without a host, the terminal runs in the application, as it always did")
  func fallsBackToALocalTerminal() async throws {
    let supervisor = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: TerminalHostLocation(
          directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmh-none-\(UUID().uuidString.prefix(8))")),
        launcher: nil,
        verifier: SameUserPeerVerifier()
      ))

    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: "printf local"), for: SessionID())

    #expect(session is PTYTerminalSession)
    #expect(await Transcript.follow(session).waitForEnd())
    #expect(await supervisor.reconnect() == .absent)
  }
}

/// Any symbol of this test image will do: its address says which file the image was loaded from.
nonisolated(unsafe) private var fixtureAnchor = 0

@Suite("The terminal host, in a process of its own", .timeLimit(.minutes(2)))
struct TerminalHostProcessTests {
  /// The first launch of a freshly linked binary that answers for itself to the system waits for
  /// the system to assess it, which after a rebuild takes seconds. The application's host is the
  /// binary already running, assessed before it ever started a terminal.
  private static let launchTimeout: Duration = .seconds(30)

  /// The fixture sits next to the test bundle, where the build put every product. The bundle is
  /// found from the image this code was loaded from: how the tests are run decides whether it is
  /// among `Bundle.allBundles` at all.
  private static func fixtureURL() throws -> URL {
    var info = Dl_info()
    let found = withUnsafeMutablePointer(to: &fixtureAnchor) { dladdr($0, &info) }
    try #require(found != 0 && info.dli_fname != nil)
    var url = URL(fileURLWithPath: String(cString: info.dli_fname))
    while url.pathComponents.count > 1, url.pathExtension != "xctest" {
      url.deleteLastPathComponent()
    }
    let fixture = url.deletingLastPathComponent().appendingPathComponent("VibeTerminalHostFixture")
    try #require(FileManager.default.isExecutableFile(atPath: fixture.path))
    return fixture
  }

  @Test("An agent left running outlives its client, and is found again when it has finished")
  func outlivesTheApplication() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmp-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try Self.fixtureURL(),
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)
    let id = SessionID()

    let application = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30)))
    // Told to finish only once the application has quit, whatever the pace of the machine.
    let go = NSTemporaryDirectory() + "vmp-go-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: go) }
    let session = try await application.start(
      TerminalTestSupport.spec(
        script: "while [ ! -e '\(go)' ]; do sleep 0.05; done; printf 'long command done\\n'"),
      for: id)
    #expect(session is HostedTerminalSession)
    guard case .running(let processIdentifier) = await session.state() else {
      Issue.record("The session did not start")
      return
    }
    // The application quits, leaving it running.
    await application.relinquish(keepRunning: true)

    #expect(isProcessAlive(processIdentifier))
    #expect(FileManager.default.createFile(atPath: go, contents: nil))
    #expect(await eventually { !isProcessAlive(processIdentifier) })
    try await Task.sleep(for: .milliseconds(300))
    let relaunched = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: nil, verifier: SameUserPeerVerifier()))
    guard case .connected(_, let sessions) = await relaunched.reconnect() else {
      Issue.record("The host did not survive its client")
      return
    }
    #expect(sessions.first?.state == .exited(code: 0))
    let adopted = try #require(await relaunched.session(for: id))
    #expect(
      String(decoding: await adopted.history().bytes, as: UTF8.self).contains("long command done"))

    // Nothing left to hold and nobody attached: the host goes, and its socket with it.
    await relaunched.relinquish(keepRunning: false)
    #expect(await eventually { !FileManager.default.fileExists(atPath: location.socketPath) })
  }

  @Test("A host told to stop says so as it goes, and the next host clears it")
  func recordsItsStopRequest() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmp-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try Self.fixtureURL(),
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)
    let application = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30)))
    let session = try await application.start(
      TerminalTestSupport.spec(script: idleScript), for: SessionID())
    let identity = try #require(await application.hostIdentity())
    await application.relinquish(keepRunning: true)
    let before = Date()

    kill(identity.processIdentifier, SIGTERM)

    #expect(await eventually { location.lastStopRequest() != nil })
    #expect(!FileManager.default.fileExists(atPath: location.socketPath))
    #expect((location.lastStopRequest() ?? .distantPast) >= before.addingTimeInterval(-1))
    guard case .running(let agent) = await session.state() else { return }
    #expect(await eventually { !isProcessAlive(agent) })

    let next = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30)))
    _ = try await next.start(TerminalTestSupport.spec(script: "true"), for: SessionID())
    #expect(location.lastStopRequest() == nil)
    await next.relinquish(keepRunning: false)
  }

  @Test("A second host for the same place leaves at once, and the first one keeps serving")
  func oneHostPerPlace() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmp-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try Self.fixtureURL(),
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)
    let application = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30)))
    let first = try await application.start(
      TerminalTestSupport.spec(script: idleScript), for: SessionID())

    try launcher.launch(at: location)
    try await Task.sleep(for: .milliseconds(500))

    // Still the first host: it still runs the first session, and still takes new ones.
    #expect(await first.state().isFinished == false)
    let second = try await application.start(
      TerminalTestSupport.spec(script: "printf served"), for: SessionID())
    #expect(second is HostedTerminalSession)
    #expect(await Transcript.follow(second).waitFor("served"))
    await application.relinquish(keepRunning: false)
  }

  @Test("A host killed under a running application takes its agents with it, at once")
  func hostDeathStopsItsAgents() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmp-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try Self.fixtureURL(),
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)
    let log = RecordingDiagnosticLog()
    let application = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30),
        diagnostics: Diagnostics(log: log, pseudonym: .ephemeral())))
    let childFile = NSTemporaryDirectory() + "vmp-child-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: childFile) }
    // An agent that survives the hang-up of its terminal, with a child that survives it too.
    let session = try await application.start(
      TerminalTestSupport.spec(
        script: """
          trap '' HUP
          /bin/sh -c 'trap "" HUP TERM; while :; do sleep 1; done' &
          echo $! > '\(childFile)'
          while :; do sleep 0.1; done
          """),
      for: SessionID())
    #expect(session is HostedTerminalSession)
    guard case .running(let agent) = await session.state() else {
      Issue.record("The session did not start")
      return
    }
    #expect(await eventually { FileManager.default.fileExists(atPath: childFile) })
    let child = try #require(
      Int32(
        (try? String(contentsOfFile: childFile, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
    let identity = try #require(await application.hostIdentity())

    kill(identity.processIdentifier, SIGKILL)

    let clock = ContinuousClock()
    let start = clock.now
    #expect(await eventually { !isProcessAlive(agent) && !isProcessAlive(child) })
    // The agent never exits by itself: any bound shows it was stopped, and a tight one measures
    // the runner's load.
    #expect(clock.now - start < .seconds(20))
    #expect(await eventually { await session.state() == .failed(.hostStopped) })
    #expect(log.events(named: "host.connectionLost").first?.value(of: "stopped") == .count(1))
  }

  @Test("An agent the application cannot show to be its own is not said to be stopped")
  func hostDeathLeavesAnUnprovenAgentUnknown() async throws {
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmp-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try Self.fixtureURL(),
      disclaimsResponsibility: TerminalTestSupport.disclaimsResponsibility)
    let log = RecordingDiagnosticLog()
    let probe = UnprovenGroupProbe()
    let application = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30),
        diagnostics: Diagnostics(log: log, pseudonym: .ephemeral()),
        processes: probe))
    let session = try await application.start(
      TerminalTestSupport.spec(script: "trap '' HUP\nwhile :; do sleep 0.1; done"),
      for: SessionID())
    guard case .running(let agent) = await session.state() else {
      Issue.record("The session did not start")
      return
    }
    defer { kill(-agent, SIGKILL) }
    let identity = try #require(await application.hostIdentity())

    kill(identity.processIdentifier, SIGKILL)

    #expect(
      await eventually {
        if case .failed(.processOutcomeUnknown) = await session.state() { return true }
        return false
      })
    #expect(probe.terminated.isEmpty)
    #expect(log.events(named: "host.connectionLost").first?.value(of: "stopped") == .count(0))
  }
}

/// A group that is always alive and never shown to be the one recorded: whether the agent really
/// survives the host is the runner's business, and not what the supervisor decides from.
private final class UnprovenGroupProbe: ProcessLivenessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private var terminatedGroups: [Int32] = []

  var terminated: [Int32] { lock.withLock { terminatedGroups } }

  func isAlive(processIdentifier: Int32) -> Bool { true }

  func startTime(of processIdentifier: Int32) -> Date? { nil }

  func terminate(processGroup: Int32) -> Bool {
    lock.withLock { terminatedGroups.append(processGroup) }
    return false
  }

  func bootTime() -> Date? { nil }
}
