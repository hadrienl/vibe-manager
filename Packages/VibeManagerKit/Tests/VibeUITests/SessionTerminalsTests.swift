import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

// The drawer of side terminals of a session (#43), with shells that do not exist.

/// A shell a test drives: it writes when told to, and ends when told to.
private actor FakeShell: TerminalSession {
  nonisolated let id: TerminalID
  private var current: TerminalProcessState
  private var bytes: [UInt8]
  private(set) var written: [[UInt8]] = []
  private var continuations: [AsyncStream<TerminalEvent>.Continuation] = []

  init(id: TerminalID, state: TerminalProcessState, history: [UInt8] = []) {
    self.id = id
    current = state
    bytes = history
  }

  func attach() -> TerminalAttachment {
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let events = AsyncStream<TerminalEvent> { continuation = $0 }
    if let continuation {
      if current.isFinished { continuation.finish() } else { continuations.append(continuation) }
    }
    return TerminalAttachment(
      state: current, history: TerminalHistorySnapshot(bytes: bytes, droppedByteCount: 0),
      events: events)
  }

  func state() -> TerminalProcessState { current }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: bytes, droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) { written.append(bytes) }

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) { finish(.terminated(signal: SIGHUP)) }

  func kill() { finish(.terminated(signal: SIGKILL)) }

  func emit(_ text: String) {
    bytes += Array(text.utf8)
    for continuation in continuations { continuation.yield(.output(Array(text.utf8))) }
  }

  func finish(_ state: TerminalProcessState) {
    guard !current.isFinished else { return }
    current = state
    for continuation in continuations {
      continuation.yield(.stateChanged(state))
      continuation.finish()
    }
    continuations.removeAll()
  }
}

/// Starts fake shells, and remembers what it was asked to start and to stop.
private actor FakeShells: TerminalSupervisor {
  private(set) var specs: [TerminalID: TerminalSpec] = [:]
  private(set) var shells: [TerminalID: FakeShell] = [:]
  private(set) var stopped: [TerminalID] = []
  private var nextPID: Int32 = 1_000
  /// Holds every start until the test opens it, the way a slow spawn would.
  private var gate: ProbeGate?

  /// A shell the terminal host kept running while the application was closed.
  func keep(_ shell: FakeShell) { shells[shell.id] = shell }

  func holdStarts(at gate: ProbeGate) { self.gate = gate }

  func start(_ spec: TerminalSpec, for id: TerminalID) async -> any TerminalSession {
    if let gate { await gate.wait() }
    nextPID += 1
    let shell = FakeShell(id: id, state: .running(processIdentifier: nextPID))
    specs[id] = spec
    shells[id] = shell
    return shell
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { shells[id] }

  func stop(id: TerminalID, gracePeriod: Duration) async {
    stopped.append(id)
    await shells[id]?.stop(gracePeriod: gracePeriod)
  }

  func stopAll(gracePeriod: Duration) async {
    for id in shells.keys { await stop(id: id, gracePeriod: gracePeriod) }
  }

  var startCount: Int { specs.count }

  /// The shells still running.
  func running() async -> [TerminalID] {
    var running: [TerminalID] = []
    for (id, shell) in shells where await !shell.state().isFinished { running.append(id) }
    return running
  }
}

/// A store whose reading waits until the test lets it.
private actor SlowStore: SessionTerminalsStore {
  let base = InMemorySessionTerminalsStore()
  let gate = ProbeGate()

  func load(_ session: SessionID) async -> SessionTerminalsDocument? {
    await gate.wait()
    return await base.load(session)
  }

  func save(_ document: SessionTerminalsDocument, for session: SessionID) async {
    await base.save(document, for: session)
  }

  func loadScrollback(of terminal: TerminalID, in session: SessionID) async -> [UInt8]? {
    await base.loadScrollback(of: terminal, in: session)
  }

  func saveScrollback(_ bytes: [UInt8], of terminal: TerminalID, in session: SessionID) async {
    await base.saveScrollback(bytes, of: terminal, in: session)
  }

  func removeScrollback(of terminal: TerminalID, in session: SessionID) async {
    await base.removeScrollback(of: terminal, in: session)
  }

  func removeAllScrollback() async { await base.removeAllScrollback() }

  func remove(_ session: SessionID) async { await base.remove(session) }

  func scrollbackByteCount() async -> Int { await base.scrollbackByteCount() }
}

/// Says a command runs in the foreground of any shell, when told to.
private final class FakeInspector: ShellProcessInspector, @unchecked Sendable {
  private let lock = NSLock()
  private var command: String?
  private var directory: String?

  func set(command: String?, directory: String? = nil) {
    lock.withLock {
      self.command = command
      self.directory = directory
    }
  }

  func inspect(processIdentifier: Int32) async -> ShellProcessSnapshot? {
    lock.withLock { ShellProcessSnapshot(currentDirectory: directory, foregroundCommand: command) }
  }
}

private struct Folders: WorkingDirectoryProbe {
  var usable: Set<String> = ["/work/app", "/work/app/web"]

  func inspect(path: String) async -> WorkingDirectoryStatus {
    usable.contains(path) ? .usable : .missing
  }
}

private struct FixedClock: SessionClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
}

@MainActor
private struct Harness {
  let shells = FakeShells()
  let store = InMemorySessionTerminalsStore()
  let inspector = FakeInspector()
  let preferences = InMemoryTerminalPreferences()
  let terminals: SessionTerminals

  init(folders: Folders = Folders()) {
    terminals = SessionTerminals(
      supervisor: shells, store: store, inspector: inspector, probe: folders,
      preferences: preferences, clock: FixedClock(), viewportTimeout: .milliseconds(1),
      timing: SessionTerminals.Timing(
        saveDelay: .milliseconds(1), inspectionInterval: .milliseconds(1),
        snapshotDelay: .milliseconds(1), snapshotInterval: .milliseconds(1)),
      sessionFolder: { _ in "/work/app" })
  }
}

@Suite("A session's drawer of side terminals", .timeLimit(.minutes(2)))
@MainActor
struct SessionTerminalsTests {
  @Test("Shown for the first time, it opens one shell in the session's folder, typing nothing")
  func firstShow() async throws {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())

    await drawer.show()

    #expect(drawer.isVisible)
    let terminal = try #require(drawer.terminals.first)
    #expect(drawer.terminals.count == 1)
    #expect(drawer.activeTerminalID == terminal.id)
    let spec = try #require(await harness.shells.specs[terminal.id])
    #expect(spec.workingDirectoryURL.path == "/work/app")
    #expect(spec.role == .auxiliary)
    #expect(spec.arguments == ["-l"])
    #expect(spec.initialInput == nil)
    #expect(await harness.shells.shells[terminal.id]?.written.isEmpty == true)
  }

  @Test("Hiding stops nothing, and showing again finds the same shells")
  func hideKeepsEverything() async throws {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())
    await drawer.show()
    let shell = try #require(drawer.terminals.first)

    drawer.hide()
    await drawer.show()

    #expect(drawer.terminals.map(\.id) == [shell.id])
    #expect(await harness.shells.stopped.isEmpty)
    #expect(await harness.shells.startCount == 1)
  }

  @Test("+ opens another shell; closing one stops it for good; closing the last hides the drawer")
  func addAndClose() async throws {
    let harness = Harness()
    let session = SessionID()
    let drawer = harness.terminals.drawer(for: session)
    await drawer.show()
    await drawer.newTerminal()
    let (first, second) = (drawer.terminals[0], drawer.terminals[1])
    #expect(drawer.activeTerminalID == second.id)
    await harness.store.saveScrollback([1, 2], of: first.id, in: session)

    await drawer.close(first.id)

    #expect(drawer.terminals.map(\.id) == [second.id])
    #expect(await harness.shells.stopped == [first.id])
    #expect(await harness.store.loadScrollback(of: first.id, in: session) == nil)
    #expect(drawer.isVisible)

    await drawer.close(second.id)

    #expect(drawer.terminals.isEmpty)
    #expect(!drawer.isVisible)
  }

  @Test("No more than eight side terminals per session")
  func limit() async {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())
    for _ in 0..<10 { await drawer.newTerminal() }

    #expect(drawer.terminals.count == SessionTerminalsDocument.maximumTerminalCount)
    #expect(!drawer.canAddTerminal)
  }

  @Test("Tabs move, are renamed, and go back to their automatic title when the name is cleared")
  func moveAndRename() async throws {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())
    await drawer.show()
    await drawer.newTerminal()
    let (first, second) = (drawer.terminals[0], drawer.terminals[1])

    drawer.move(second.id, to: 0)
    drawer.rename(first.id, to: "  Tests  ")

    #expect(drawer.terminals.map(\.id) == [second.id, first.id])
    #expect(first.title == "Tests")
    drawer.rename(first.id, to: "")
    #expect(first.title == "app")
    drawer.activateNeighbour(offset: 1)
    #expect(drawer.activeTerminalID == first.id)
    drawer.activateNeighbour(offset: 1)
    #expect(drawer.activeTerminalID == second.id)
  }

  @Test("A tab is titled by its command while one runs, then by its folder")
  func titles() async throws {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())
    harness.inspector.set(command: "npm run dev", directory: "/work/app/web")
    await drawer.show()
    let terminal = try #require(drawer.terminals.first)

    await waitUntil("the title the shell set is shown") { terminal.title == "npm run dev" }
    #expect(terminal.isRunningCommand)
    harness.inspector.set(command: nil, directory: "/work/app/web")
    await harness.shells.shells[terminal.id]?.emit("$ ")
    await waitUntil("the title set by hand is shown") { terminal.title == "web" }
    #expect(!terminal.isRunningCommand)
  }

  @Test("Closing the session writes each history down, stops the shells, and keeps the drawer")
  func shutDownKeepsTheDrawer() async throws {
    let harness = Harness()
    let session = SessionID()
    let drawer = harness.terminals.drawer(for: session)
    await drawer.show()
    await drawer.newTerminal()
    drawer.setHeight(310)
    let ids = drawer.terminals.map(\.id)
    await harness.shells.shells[ids[0]]?.emit("first history\r\n")

    await harness.terminals.shutDown(session)

    #expect(drawer.terminals.isEmpty)
    #expect(Set(await harness.shells.stopped) == Set(ids))
    #expect(
      await harness.store.loadScrollback(of: ids[0], in: session)
        == Array("first history\r\n".utf8))
    let document = try #require(await harness.store.load(session))
    #expect(document.terminals.map(\.id) == ids)
    #expect(document.isVisible)
    #expect(document.height == 310)
    #expect(document.activeTerminal == ids[1])
  }

  @Test(
    "Reopened, the drawer comes back: same tabs, same order, same one in front, each a new shell under its history"
  )
  func restoresAfterReopening() async throws {
    let first = Harness()
    let session = SessionID()
    let drawer = first.terminals.drawer(for: session)
    await drawer.show()
    await drawer.newTerminal()
    first.inspector.set(command: nil, directory: "/work/app/web")
    let ids = drawer.terminals.map(\.id)
    drawer.rename(ids[1], to: "Tests")
    drawer.activate(ids[0])
    await first.shells.shells[ids[0]]?.emit("$ npm run dev\r\nready\r\n")
    await waitUntil("the folder the shell moved to is known") {
      drawer.terminals[0].currentDirectory == "/work/app/web"
    }
    await first.terminals.shutDown(session)

    // A relaunch: a new workspace over the same store.
    let second = Harness()
    for id in [session] {
      if let document = await first.store.load(id) { await second.store.save(document, for: id) }
    }
    for id in ids {
      if let bytes = await first.store.loadScrollback(of: id, in: session) {
        await second.store.saveScrollback(bytes, of: id, in: session)
      }
    }

    await second.terminals.sessionStarted(session)
    let restored = second.terminals.drawer(for: session)

    #expect(restored.isVisible)
    #expect(restored.terminals.map(\.id) == ids)
    #expect(restored.activeTerminalID == ids[0])
    #expect(restored.terminals[1].title == "Tests")
    let spec = try #require(await second.shells.specs[ids[0]])
    #expect(spec.workingDirectoryURL.path == "/work/app/web")
    #expect(spec.initialInput == nil)
    #expect(await second.shells.shells[ids[0]]?.written.isEmpty == true)
    let notice = restored.terminals[0].pane.prelude
    let history = Array("$ npm run dev\r\nready\r\n".utf8)
    #expect(notice.starts(with: history))
    #expect(Array(notice.dropFirst(history.count)).starts(with: DrawerRestoration.softReset))
    #expect(
      String(decoding: notice, as: UTF8.self).hasSuffix(
        DrawerRestoration.separator(for: .resumed, at: FixedClock().now())))
  }

  @Test("A folder that is gone falls back on the session's, and says so in the terminal")
  func restoresIntoTheSessionFolder() async throws {
    let session = SessionID()
    let terminal = TerminalID()
    let harness = Harness(folders: Folders(usable: ["/work/app"]))
    await harness.store.save(
      SessionTerminalsDocument(
        isVisible: true, activeTerminal: terminal,
        terminals: [DrawerTerminalRecord(id: terminal, directory: "/work/app/feature-x")]),
      for: session)

    await harness.terminals.sessionStarted(session)
    let drawer = harness.terminals.drawer(for: session)

    let spec = try #require(await harness.shells.specs[terminal])
    #expect(spec.workingDirectoryURL.path == "/work/app")
    let notice = String(decoding: drawer.terminals[0].pane.prelude, as: UTF8.self)
    #expect(
      notice.contains("/work/app/feature-x no longer exists: opened in the session's folder."))
  }

  @Test("What a restored tab shows stays above its new shell, on screen and in what is written")
  func restoredHistoryIsKept() async throws {
    let session = SessionID()
    let terminal = TerminalID()
    let harness = Harness()
    await harness.store.save(
      SessionTerminalsDocument(
        isVisible: true, activeTerminal: terminal,
        terminals: [DrawerTerminalRecord(id: terminal, directory: "/work/app")]),
      for: session)
    await harness.store.saveScrollback(Array("before\r\n".utf8), of: terminal, in: session)

    await harness.terminals.sessionStarted(session)
    let drawer = harness.terminals.drawer(for: session)
    let pane = drawer.terminals[0].pane
    let prelude = pane.prelude
    #expect(prelude.starts(with: Array("before\r\n".utf8)))
    // Not handed over once: a view rebuilt later replays it too.
    #expect(pane.prelude == prelude)

    await harness.shells.shells[terminal]?.emit("after\r\n")
    await harness.terminals.shutDown(session)

    #expect(
      await harness.store.loadScrollback(of: terminal, in: session)
        == prelude + Array("after\r\n".utf8))
    let document = try #require(await harness.store.load(session))
    #expect(document.terminals[0].preludeByteCount == prelude.count)
  }

  @Test("Restarted, a tab keeps everything it showed above the new shell")
  func relaunchKeepsTheHistory() async throws {
    let harness = Harness()
    let session = SessionID()
    let drawer = harness.terminals.drawer(for: session)
    await drawer.show()
    let terminal = try #require(drawer.terminals.first)
    let shell = try #require(await harness.shells.shells[terminal.id])
    await shell.emit("failed build\r\n")
    await shell.finish(.exited(code: 1))
    await waitUntil("the exit status is known") { terminal.exitStatus != nil }

    await drawer.relaunch(terminal.id)

    #expect(terminal.isRunning)
    #expect(terminal.pane.prelude.starts(with: Array("failed build\r\n".utf8)))
    await harness.terminals.shutDown(session)
    let written = try #require(await harness.store.loadScrollback(of: terminal.id, in: session))
    #expect(written.starts(with: Array("failed build\r\n".utf8)))
  }

  @Test("A shell the host kept is taken back under what was shown above it")
  func adoptedShellKeepsItsPrelude() async throws {
    let session = SessionID()
    let terminal = TerminalID()
    let harness = Harness()
    let prelude = Array("older\r\n── Resumed ──\r\n".utf8)
    await harness.store.save(
      SessionTerminalsDocument(
        isVisible: true, activeTerminal: terminal,
        terminals: [
          DrawerTerminalRecord(
            id: terminal, directory: "/work/app", preludeByteCount: prelude.count)
        ]),
      for: session)
    await harness.store.saveScrollback(
      prelude + Array("$ ls\r\n".utf8), of: terminal, in: session)
    let kept = FakeShell(
      id: terminal, state: .running(processIdentifier: 42), history: Array("$ ls\r\n".utf8))
    await harness.shells.keep(kept)

    await harness.terminals.sessionAdopted(session)
    let drawer = harness.terminals.drawer(for: session)

    #expect(await harness.shells.startCount == 0)
    #expect(drawer.terminals[0].pane.prelude == prelude)
  }

  @Test("A hidden drawer is not restored before it is shown")
  func hiddenDrawerWaits() async {
    let session = SessionID()
    let harness = Harness()
    await harness.store.save(
      SessionTerminalsDocument(
        isVisible: false, terminals: [DrawerTerminalRecord(id: TerminalID())]),
      for: session)

    await harness.terminals.sessionStarted(session)
    let drawer = harness.terminals.drawer(for: session)

    #expect(await harness.shells.startCount == 0)
    #expect(drawer.terminalCount == 1)
    await drawer.show()
    #expect(await harness.shells.startCount == 1)
  }

  @Test("A shell the host kept running is taken back as it is: nothing started, nothing typed")
  func adoptsAKeptShell() async throws {
    let session = SessionID()
    let terminal = TerminalID()
    let harness = Harness()
    let kept = FakeShell(id: terminal, state: .running(processIdentifier: 77))
    await harness.shells.keep(kept)
    await harness.store.save(
      SessionTerminalsDocument(
        isVisible: false, terminals: [DrawerTerminalRecord(id: terminal)]),
      for: session)

    await harness.terminals.sessionAdopted(session)

    let drawer = harness.terminals.drawer(for: session)
    #expect(drawer.terminals.map(\.id) == [terminal])
    #expect(await harness.shells.startCount == 0)
    #expect(drawer.terminals[0].pane.session === kept)
    #expect(await kept.written.isEmpty)
  }

  @Test("`exit` closes its tab; a shell that fails keeps its tab, and says so when unseen")
  func shellEndings() async throws {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())
    await drawer.show()
    await drawer.newTerminal()
    let (failing, exiting) = (drawer.terminals[0], drawer.terminals[1])

    await harness.shells.shells[exiting.id]?.finish(.exited(code: 0))
    await waitUntil("only the failing terminal is left") {
      drawer.terminals.map(\.id) == [failing.id]
    }

    drawer.hide()
    await harness.shells.shells[failing.id]?.finish(.exited(code: 1))
    await waitUntil("the failed exit is marked unseen") { failing.hasUnseenExit }
    #expect(drawer.attention == .ended)
    #expect(drawer.terminals.map(\.id) == [failing.id])

    await drawer.relaunch(failing.id)
    #expect(await harness.shells.shells[failing.id]?.state() == .running(processIdentifier: 1_003))
  }

  @Test("Output in a terminal nobody sees is signalled until it is seen")
  func unseenOutput() async throws {
    let harness = Harness()
    let drawer = harness.terminals.drawer(for: SessionID())
    drawer.isOnScreen = true
    await drawer.show()
    await drawer.newTerminal()
    let (background, front) = (drawer.terminals[0], drawer.terminals[1])

    await harness.shells.shells[front.id]?.emit("seen")
    await harness.shells.shells[background.id]?.emit("not seen")

    await waitUntil("the output in the background is marked unseen") { background.hasUnseenOutput }
    #expect(!front.hasUnseenOutput)
    #expect(drawer.attention == .output)
    #expect(drawer.noticeTerminal === background)

    drawer.activate(background.id)
    #expect(!background.hasUnseenOutput)
    #expect(drawer.attention == DrawerAttention.none)
  }

  @Test("Each session has its own drawer, and only its own terminals")
  func separateSessions() async {
    let harness = Harness()
    let first = harness.terminals.drawer(for: SessionID())
    let second = harness.terminals.drawer(for: SessionID())

    await first.show()
    await first.newTerminal()
    await second.show()

    #expect(first.terminals.count == 2)
    #expect(second.terminals.count == 1)
    #expect(Set(first.terminals.map(\.id)).isDisjoint(with: second.terminals.map(\.id)))
  }

  @Test("A drawer shut down while it is being restored starts nothing after, and leaves nothing")
  func shutDownDuringRestore() async throws {
    let harness = Harness()
    let session = SessionID()
    let ids = [TerminalID(), TerminalID()]
    let document = SessionTerminalsDocument(
      isVisible: true, activeTerminal: ids[0],
      terminals: ids.map { DrawerTerminalRecord(id: $0, directory: "/work/app") })
    await harness.store.save(document, for: session)
    let gate = ProbeGate()
    await harness.shells.holdStarts(at: gate)

    let restoring = Task { await harness.terminals.sessionStarted(session) }
    let drawer = harness.terminals.drawer(for: session)
    await waitUntil("the second terminal is open") { drawer.terminals.count == 2 }
    let closing = Task { await harness.terminals.shutDown(session) }
    await gate.open()
    await restoring.value
    await closing.value

    #expect(await harness.shells.running().isEmpty)
    #expect(await harness.shells.startCount <= 1)
    // The document is kept whole, for the next reopening.
    #expect(await harness.store.load(session)?.terminals.map(\.id) == ids)
  }

  @Test("⌘J while the drawer is being read opens no tab of its own over the ones written down")
  func showDuringLoad() async throws {
    let session = SessionID()
    let written = TerminalID()
    let store = SlowStore()
    await store.base.save(
      SessionTerminalsDocument(
        isVisible: false, terminals: [DrawerTerminalRecord(id: written, directory: "/work/app")]),
      for: session)
    let shells = FakeShells()
    let terminals = SessionTerminals(
      supervisor: shells, store: store, probe: Folders(), clock: FixedClock(),
      viewportTimeout: .milliseconds(1), sessionFolder: { _ in "/work/app" })
    let drawer = terminals.drawer(for: session)

    let preparing = Task { await terminals.prepare(session) }
    let showing = Task { await drawer.show() }
    await store.gate.open()
    await preparing.value
    await showing.value

    #expect(drawer.terminals.map(\.id) == [written])
    #expect(await shells.startCount == 1)
  }

  @Test("With the history turned off, nothing is written, and what was is erased")
  func historyOff() async throws {
    let harness = Harness()
    let session = SessionID()
    let drawer = harness.terminals.drawer(for: session)
    await drawer.show()
    let terminal = try #require(drawer.terminals.first)
    await harness.store.saveScrollback([9], of: TerminalID(), in: SessionID())

    await harness.terminals.setKeepsScrollback(false)
    await harness.shells.shells[terminal.id]?.emit("secret token")
    await harness.terminals.shutDown(session)

    #expect(await harness.store.scrollbackByteCount() == 0)
    #expect(!harness.preferences.keepsScrollback)
  }
}
