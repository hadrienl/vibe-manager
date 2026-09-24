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

  init(idleGracePeriod: Duration = .seconds(60)) throws {
    location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmh-\(UUID().uuidString.prefix(8))", isDirectory: true))
    try location.prepare()
    let listener = try UnixSocket.listen(at: location.socketPath)
    let idle = idle
    server = TerminalHostServer(
      configuration: TerminalHostServer.Configuration(
        verifier: SameUserPeerVerifier(), idleGracePeriod: idleGracePeriod),
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

  func waitFor(_ needle: String, timeout: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !text.contains(needle), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return text.contains(needle)
  }

  func waitForEnd(timeout: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !isFinished, ContinuousClock.now < deadline {
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

@Suite("The terminal host, in process")
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

    #expect(await transcript.waitFor("end-of-output", timeout: .seconds(20)))
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
      TerminalTestSupport.spec(script: "printf 'before\\n'; sleep 1; printf 'after\\n'"), for: id)
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
    _ = try await first.start(
      TerminalTestSupport.spec(script: "sleep 0.2; printf 'last words\\n'; exit 4"), for: id)
    await first.relinquish(keepRunning: true)

    #expect(await eventually { await host.server.sessionCount == 1 })
    try await Task.sleep(for: .milliseconds(800))
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

  @Test("A client that vanishes without saying goodbye takes its agents with it")
  func abruptDisconnectStopsEverything() async throws {
    let host = try InProcessTerminalHost()
    let supervisor = host.supervisor()
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: idleScript), for: SessionID())
    guard case .running(let processIdentifier) = await session.state() else {
      Issue.record("The session did not start")
      return
    }

    await supervisor.dropConnection()

    #expect(await eventually { !isProcessAlive(processIdentifier) })
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

@Suite("The terminal host, in a process of its own")
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
    let launcher = ExecutableTerminalHostLauncher(executableURL: try Self.fixtureURL())
    let id = SessionID()

    let application = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: launcher, verifier: SameUserPeerVerifier(),
        launchTimeout: Self.launchTimeout, replyTimeout: .seconds(30)))
    let session = try await application.start(
      TerminalTestSupport.spec(script: "sleep 1; printf 'long command done\\n'"), for: id)
    #expect(session is HostedTerminalSession)
    // The application quits, leaving it running.
    await application.relinquish(keepRunning: true)

    try await Task.sleep(for: .milliseconds(1_500))
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
    let launcher = ExecutableTerminalHostLauncher(executableURL: try Self.fixtureURL())
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
    let launcher = ExecutableTerminalHostLauncher(executableURL: try Self.fixtureURL())
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
}
