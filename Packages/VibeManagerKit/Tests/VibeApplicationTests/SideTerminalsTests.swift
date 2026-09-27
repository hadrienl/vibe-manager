import Foundation
import Testing
import VibeApplication
import VibeDomain

// The drawer of side terminals of a session (#43): what is decided without a process.

/// A folder probe that knows which paths exist.
private struct KnownFolders: WorkingDirectoryProbe {
  let usable: Set<String>

  func inspect(path: String) async -> WorkingDirectoryStatus {
    usable.contains(path) ? .usable : .missing
  }
}

private let resumedAt = Date(timeIntervalSince1970: 1_790_000_000)

@Suite("Putting a side terminal back")
struct DrawerRestorationTests {
  @Test("The remembered folder is used when it can still be entered")
  func remembersTheFolder() async {
    let result = await DrawerRestoration.directory(
      remembered: "/work/app/web", sessionFolder: "/work/app", home: "/Users/me",
      probe: KnownFolders(usable: ["/work/app/web", "/work/app"]))

    #expect(result.path == "/work/app/web")
    #expect(result.fallback == nil)
  }

  @Test("A folder that is gone falls back on the session's, saying which one is gone")
  func fallsBackOnTheSessionFolder() async {
    let result = await DrawerRestoration.directory(
      remembered: "/work/app/feature-x", sessionFolder: "/work/app", home: "/Users/me",
      probe: KnownFolders(usable: ["/work/app"]))

    #expect(result.path == "/work/app")
    #expect(result.fallback == .sessionFolder(missing: "/work/app/feature-x"))
  }

  @Test("With the session's folder gone too — a removed worktree — the home folder is used")
  func fallsBackOnHome() async {
    let result = await DrawerRestoration.directory(
      remembered: "/work/wt/src", sessionFolder: "/work/wt", home: "/Users/me",
      probe: KnownFolders(usable: []))

    #expect(result.path == "/Users/me")
    #expect(result.fallback == .home(missing: "/work/wt/src"))
  }

  @Test("A new tab opens in the session's folder, or at home when it is gone")
  func newTabFolder() async {
    let present = await DrawerRestoration.directory(
      remembered: nil, sessionFolder: "/work/app", home: "/Users/me",
      probe: KnownFolders(usable: ["/work/app"]))
    let gone = await DrawerRestoration.directory(
      remembered: nil, sessionFolder: "/work/wt", home: "/Users/me",
      probe: KnownFolders(usable: []))

    #expect(present == ("/work/app", nil))
    #expect(gone.path == "/Users/me")
    #expect(gone.fallback == .home(missing: "/work/wt"))
  }

  @Test("The history comes first, then the reset, the dated separator and the reason for the move")
  func noticeOrder() {
    let scrollback = Array("$ npm run dev\r\nready\r\n".utf8)
    let notice = DrawerRestoration.notice(
      scrollback: scrollback, resumption: .resumed, at: resumedAt,
      fallback: .sessionFolder(missing: "/gone"))
    let text = String(decoding: notice, as: UTF8.self)

    #expect(notice.starts(with: scrollback))
    let afterHistory = Array(notice.dropFirst(scrollback.count))
    #expect(afterHistory.starts(with: DrawerRestoration.softReset))
    let separator = DrawerRestoration.separator(for: .resumed, at: resumedAt)
    #expect(text.contains(separator))
    #expect(
      text.hasSuffix("── /gone no longer exists: opened in the session's folder. ──\u{1B}[0m\r\n"))
    #expect(text.range(of: separator)!.lowerBound < text.range(of: "/gone")!.lowerBound)
  }

  @Test("Without a history, nothing is reset: the separator is all there is")
  func noticeWithoutHistory() {
    let notice = DrawerRestoration.notice(
      scrollback: nil, resumption: .relaunched, at: resumedAt, fallback: nil)

    #expect(
      String(decoding: notice, as: UTF8.self)
        == DrawerRestoration.separator(for: .relaunched, at: resumedAt))
  }

  @Test("The separator says the shell is new, and resumed or restarted")
  func separatorWording() {
    let resumed = DrawerRestoration.separator(for: .resumed, at: resumedAt)
    let relaunched = DrawerRestoration.separator(for: .relaunched, at: resumedAt)

    #expect(resumed.contains("Resumed"))
    #expect(resumed.contains("new shell"))
    #expect(relaunched.contains("Restarted"))
    #expect(resumed.hasPrefix("\r\n\u{1B}[2m── "))
  }

  @Test("A folder's name cannot slip an escape sequence into the terminal")
  func pathIsMadePrintable() {
    let message = DrawerRestoration.fallbackMessage(
      .home(missing: "/tmp/\u{1B}]0;pwned\u{07}/\u{202E}txt.sh"))

    #expect(!message.contains("\u{1B}"))
    #expect(!message.contains("\u{07}"))
    #expect(!message.contains("\u{202E}"))
    #expect(message.contains("/tmp/?]0;pwned?/?txt.sh"))
  }
}

@Suite("A session's drawer, as it is written down")
struct SessionTerminalsDocumentTests {
  @Test("Read back as it was written, identifiers as plain UUID strings")
  func roundTrip() throws {
    let first = TerminalID()
    let second = TerminalID()
    let document = SessionTerminalsDocument(
      isVisible: true, height: 260, activeTerminal: second,
      terminals: [
        DrawerTerminalRecord(
          id: first, title: nil, directory: "/work/app/web",
          size: TerminalSize(columns: 132, rows: 14), lastSeenTitle: "npm run dev"),
        DrawerTerminalRecord(id: second, title: "Tests", directory: "/work/app"),
      ])

    let data = try JSONEncoder().encode(document)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(try JSONDecoder().decode(SessionTerminalsDocument.self, from: data) == document)
    #expect(json.contains("\"\(second.rawValue.uuidString)\""))
    #expect(!json.contains("rawValue"))
    #expect(json.contains("\"schema\":1"))
  }

  @Test("A height edited by hand out of bounds is brought back within them")
  func clampsHeight() throws {
    let json = #"{"schema":1,"isVisible":true,"height":5,"terminals":[]}"#

    let document = try JSONDecoder().decode(
      SessionTerminalsDocument.self, from: Data(json.utf8))

    #expect(document.height == SessionTerminalsDocument.heightRange.lowerBound)
  }
}

@Suite("Side terminals in the runtime document")
struct AuxiliaryRuntimeTests {
  private let launch = Date(timeIntervalSince1970: 1_700_000_000)
  private let quitAt = Date(timeIntervalSince1970: 1_700_000_600)
  private let identity = TerminalHostIdentity(
    processIdentifier: 815, processStartedAt: Date(timeIntervalSince1970: 1_699_999_900))

  @Test("A quit that keeps a session running keeps its side terminals, and only its")
  func detachedKeepsTheKeptSessionsTerminals() async {
    let store = EphemeralSessionRuntimeStateStore()
    let recorder = SessionRuntimeRecorder(
      store: store, processIdentifier: 4242, probe: RestorationProcesses(),
      clock: RestorationClock(launch))
    let kept = SessionID()
    let stopped = SessionID()
    let keptTerminal = TerminalID()
    await recorder.started(kept, processGroup: 900)
    await recorder.auxiliaryStarted(keptTerminal, of: kept, processGroup: 901)
    await recorder.auxiliaryStarted(TerminalID(), of: stopped, processGroup: 902)

    await recorder.markDetached(keeping: [kept], resuming: [stopped], host: identity)

    #expect(await store.read()?.auxiliary?.map(\.terminalID) == [keptTerminal])
  }

  @Test("A plain quit leaves no side terminal to look for")
  func stoppedForgetsThem() async {
    let store = EphemeralSessionRuntimeStateStore()
    let recorder = SessionRuntimeRecorder(
      store: store, processIdentifier: 4242, probe: RestorationProcesses(),
      clock: RestorationClock(launch))
    await recorder.auxiliaryStarted(TerminalID(), of: SessionID(), processGroup: 901)

    await recorder.markStopped(resuming: [])

    #expect(await store.read()?.auxiliary == nil)
  }

  @Test("Written and read with plain identifiers, and absent from an older document")
  func encoding() throws {
    let record = AuxiliaryRuntimeRecord(
      terminalID: TerminalID(), sessionID: SessionID(), processGroup: 901)
    let data = try JSONEncoder().encode(record)

    #expect(try JSONDecoder().decode(AuxiliaryRuntimeRecord.self, from: data) == record)
    #expect(!(String(data: data, encoding: .utf8) ?? "").contains("rawValue"))
  }

  private func detect(
    stored: [WorkSession],
    document: SessionRuntimeState,
    host: SideTerminalHost,
    processes: RestorationProcesses = RestorationProcesses()
  ) async -> PreviousShutdown {
    let repository = RestorationRepository(sessions: stored)
    let recorder = SessionRuntimeRecorder(
      store: EphemeralSessionRuntimeStateStore(state: document), processIdentifier: 4242,
      probe: processes, clock: RestorationClock(quitAt))
    return await DetectPreviousShutdown(
      repository: repository, recorder: recorder, processes: processes,
      clock: RestorationClock(quitAt), processIdentifier: 4242, host: host)()
  }

  private func activeSession() -> WorkSession {
    WorkSession(
      name: "Drawer", initialPrompt: "Open a drawer.",
      agent: SessionAgentConfiguration(providerID: "stub"), status: .active,
      createdAt: launch, updatedAt: launch)
  }

  @Test("After a quit that kept them running, a session's side terminals are taken back with it")
  func keepsSideTerminalsOfAdoptedSessions() async {
    let session = activeSession()
    let kept = TerminalID()
    let stray = TerminalID()
    let document = SessionRuntimeState(
      phase: .detached, processIdentifier: 1_001, launchedAt: launch, updatedAt: quitAt,
      stoppedAt: quitAt, sessions: [SessionRuntimeRecord(sessionID: session.id)], host: identity,
      auxiliary: [AuxiliaryRuntimeRecord(terminalID: kept, sessionID: session.id)])
    let host = SideTerminalHost(
      .connected(
        identity,
        sessions: [
          HostedSessionSummary(id: session.id.agentTerminal, state: .running(processIdentifier: 7)),
          HostedSessionSummary(id: kept, state: .running(processIdentifier: 8)),
          HostedSessionSummary(id: stray, state: .running(processIdentifier: 9)),
        ]))

    let verdict = await detect(stored: [session], document: document, host: host)

    guard case .detached(let detached) = verdict else {
      Issue.record("Expected the sessions to be taken back, got \(verdict)")
      return
    }
    #expect(detached.running == [session.id])
    // The one the document names stays; one nobody names is let go.
    #expect(await host.discarded == [stray])
  }

  @Test("A side terminal whose session did not come back is let go")
  func letsGoOfOrphanedSideTerminals() async {
    let session = activeSession()
    let orphan = TerminalID()
    let document = SessionRuntimeState(
      phase: .detached, processIdentifier: 1_001, launchedAt: launch, updatedAt: quitAt,
      stoppedAt: quitAt, sessions: [SessionRuntimeRecord(sessionID: session.id)], host: identity,
      auxiliary: [AuxiliaryRuntimeRecord(terminalID: orphan, sessionID: session.id)])
    // The agent ended while the application was closed: its session is closed, not taken back.
    let host = SideTerminalHost(
      .connected(
        identity,
        sessions: [
          HostedSessionSummary(id: session.id.agentTerminal, state: .exited(code: 0)),
          HostedSessionSummary(id: orphan, state: .running(processIdentifier: 8)),
        ]))

    _ = await detect(stored: [session], document: document, host: host)

    #expect(await host.discarded == [orphan])
  }

  @Test("A shell that outlived a crashed host is stopped once it is shown to be the same")
  func stopsLeftoverShells() async {
    let session = activeSession()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let document = SessionRuntimeState(
      phase: .detached, processIdentifier: 1_001, launchedAt: launch, updatedAt: quitAt,
      stoppedAt: quitAt, sessions: [SessionRuntimeRecord(sessionID: session.id)], host: identity,
      auxiliary: [
        AuxiliaryRuntimeRecord(
          terminalID: TerminalID(), sessionID: session.id, processGroup: 901,
          processStartedAt: startedAt)
      ])
    let processes = RestorationProcesses(alive: [901], startTimes: [901: startedAt])

    _ = await detect(
      stored: [session], document: document, host: SideTerminalHost(.absent),
      processes: processes)

    #expect(processes.terminated.contains(901))
  }

  @Test(
    "The jobs a crashed shell ran in groups of their own are stopped with it, or after it",
    arguments: [true, false])
  func stopsLeftoverJobs(shellAlive: Bool) async {
    let session = activeSession()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let document = SessionRuntimeState(
      phase: .detached, processIdentifier: 1_001, launchedAt: launch, updatedAt: quitAt,
      stoppedAt: quitAt, sessions: [SessionRuntimeRecord(sessionID: session.id)], host: identity,
      auxiliary: [
        AuxiliaryRuntimeRecord(
          terminalID: TerminalID(), sessionID: session.id, processGroup: 901,
          processStartedAt: startedAt)
      ])
    // The shell may have died of its terminal's hang-up; a job started with `&` did not.
    let processes = RestorationProcesses(
      alive: shellAlive ? [901] : [], startTimes: [901: startedAt], jobs: [901: [950, 960]])

    _ = await detect(
      stored: [session], document: document, host: SideTerminalHost(.absent),
      processes: processes)

    #expect(Set(processes.terminated).isSuperset(of: [950, 960]))
    #expect(processes.terminated.contains(901) == shellAlive)
  }

  @Test("A shell group whose number now names another process is left alone, and its jobs too")
  func leavesRecycledShellsAlone() async {
    let session = activeSession()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let document = SessionRuntimeState(
      phase: .detached, processIdentifier: 1_001, launchedAt: launch, updatedAt: quitAt,
      stoppedAt: quitAt, sessions: [SessionRuntimeRecord(sessionID: session.id)], host: identity,
      auxiliary: [
        AuxiliaryRuntimeRecord(
          terminalID: TerminalID(), sessionID: session.id, processGroup: 901,
          processStartedAt: startedAt)
      ])
    let processes = RestorationProcesses(
      alive: [901], startTimes: [901: startedAt.addingTimeInterval(3_600)],
      jobs: [901: [950]])

    _ = await detect(
      stored: [session], document: document, host: SideTerminalHost(.absent),
      processes: processes)

    #expect(processes.terminated.isEmpty)
  }
}

/// A terminal host that says which terminals it was asked to let go of.
private actor SideTerminalHost: TerminalHosting {
  private let status: TerminalHostStatus
  private(set) var discarded: [TerminalID] = []

  init(_ status: TerminalHostStatus) {
    self.status = status
  }

  func reconnect() -> TerminalHostStatus { status }

  func hostIdentity() -> TerminalHostIdentity? { nil }

  func discard(_ id: TerminalID) { discarded.append(id) }

  func relinquish(keepRunning: Bool) {}

  func stepAway() {}
}
