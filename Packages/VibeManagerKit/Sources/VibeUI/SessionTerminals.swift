import Foundation
import Observation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// What the launcher tells a session's side terminals (#43): they belong to the session, so they
/// follow what happens to its agent.
@MainActor
public protocol SessionSideTerminals: AnyObject {
  /// The session's agent was started: a drawer that was on screen when the session was closed
  /// comes back with it.
  func sessionStarted(_ id: SessionID) async
  /// The session's agent was taken back from the terminal host after a relaunch: so are the side
  /// terminals it kept running.
  func sessionAdopted(_ id: SessionID) async
  /// The session is closing, or archived: its side terminals are written down, then stopped.
  func shutDown(_ id: SessionID) async
  /// The session is left running in the terminal host as the application quits: its side
  /// terminals stay there with it, written down in case the host does not last.
  func handOff(_ id: SessionID) async
}

/// Whether a side terminal nobody is looking at has something to say.
public enum DrawerAttention: Equatable, Sendable {
  case none
  /// One wrote something since it was last seen.
  case output
  /// One's shell ended since it was last seen.
  case ended
}

/// One tab of a session's drawer: a terminal of its own, the very component the agent's terminal
/// uses (#4), so everything the main terminal does, this one does.
@MainActor
@Observable
public final class DrawerTerminal: Identifiable {
  public let id: TerminalID
  public let pane: TerminalPaneModel
  /// The name the user gave the tab. `nil` or empty, the title follows the shell.
  public internal(set) var customTitle: String?
  public internal(set) var currentDirectory: String?
  /// What the shell runs in the foreground, or `nil` at its prompt.
  public internal(set) var foregroundCommand: String?
  public internal(set) var hasUnseenOutput = false
  public internal(set) var hasUnseenExit = false
  /// The title written down last time, until the new shell has said anything.
  var lastSeenTitle: String?

  @ObservationIgnored var watch: Task<Void, Never>?
  @ObservationIgnored var inspection: Task<Void, Never>?
  @ObservationIgnored var snapshot: Task<Void, Never>?
  @ObservationIgnored var lastSnapshotAt: ContinuousClock.Instant?
  /// Set while this tab is being closed or stopped on purpose: its end is not news.
  @ObservationIgnored var isEnding = false

  init(id: TerminalID, pane: TerminalPaneModel) {
    self.id = id
    self.pane = pane
  }

  /// The name the user gave, else the command in the foreground, else the folder.
  public var title: String {
    if let customTitle, !customTitle.isEmpty { return customTitle }
    if let foregroundCommand { return foregroundCommand }
    if let currentDirectory { return Self.displayName(of: currentDirectory) }
    if let lastSeenTitle, !lastSeenTitle.isEmpty { return lastSeenTitle }
    return String(localized: "Terminal", bundle: .module, comment: "A side terminal's title.")
  }

  /// Whether closing it would stop something the user started.
  public var isRunningCommand: Bool {
    foregroundCommand != nil && isRunning
  }

  public var isRunning: Bool {
    pane.status == .running || pane.status == .starting
  }

  /// What its shell ended with, once it has: shown over the tab with Restart and Close.
  public var exitStatus: TerminalPaneModel.Status? {
    switch pane.status {
    case .exited, .terminated: return pane.status
    case .starting, .running, .failed: return nil
    }
  }

  static func displayName(of path: String) -> String {
    let standardized = (path as NSString).standardizingPath
    if standardized == (NSHomeDirectory() as NSString).standardizingPath { return "~" }
    let name = (standardized as NSString).lastPathComponent
    return name.isEmpty ? standardized : name
  }

  func cancelTasks() {
    watch?.cancel()
    watch = nil
    inspection?.cancel()
    inspection = nil
    snapshot?.cancel()
    snapshot = nil
  }
}

/// What a drawer needs from the system, handed down by `SessionTerminals`.
struct DrawerDependencies {
  let supervisor: any TerminalSupervisor
  let store: any SessionTerminalsStore
  let inspector: any ShellProcessInspector
  let probe: any WorkingDirectoryProbe
  let recorder: SessionRuntimeRecorder?
  let preferences: any TerminalPreferences
  let clock: any SessionClock
  let diagnostics: Diagnostics
  let sessionFolder: @MainActor (SessionID) async -> String?
  let viewportTimeout: Duration
  let timing: SessionTerminals.Timing
}

/// A session's drawer of side terminals: its tabs, which one is in front, whether it is shown and
/// how tall. One per session, never shared.
@MainActor
@Observable
public final class SessionTerminalDrawer {
  public let sessionID: SessionID
  public private(set) var isVisible = false
  public private(set) var height = SessionTerminalsDocument.defaultHeight
  /// In the order of the tabs.
  public private(set) var terminals: [DrawerTerminal] = []
  public private(set) var activeTerminalID: TerminalID?
  /// Whether the drawer is mounted on screen: the session is the one shown.
  public var isOnScreen = false {
    didSet { if isOnScreen { markActiveSeen() } }
  }
  /// Whether the keyboard is in one of its terminals: ⌘W and ⌃⇥ then act on its tabs.
  public var isFocused: Bool {
    terminals.contains { $0.pane.hasKeyboardFocus }
  }

  /// The document read at the first use, whose tabs have not been built yet.
  @ObservationIgnored private var pending: SessionTerminalsDocument?
  @ObservationIgnored private var isLoaded = false
  @ObservationIgnored private var isRestoring = false
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private let dependencies: DrawerDependencies

  /// How long a side terminal's shell and what it runs are given to stop before they are killed.
  /// Shorter than an agent's: an interactive shell ignores `SIGTERM`, and a session closing, or an
  /// application quitting on its deadline, waits for these stops.
  static let stopGracePeriod: Duration = .seconds(1)

  init(sessionID: SessionID, dependencies: DrawerDependencies) {
    self.sessionID = sessionID
    self.dependencies = dependencies
  }

  public var activeTerminal: DrawerTerminal? {
    terminals.first { $0.id == activeTerminalID }
  }

  /// How many tabs the drawer has, including those written down and not rebuilt yet.
  public var terminalCount: Int {
    pending.map { $0.terminals.count } ?? terminals.count
  }

  public var canAddTerminal: Bool {
    terminals.count < SessionTerminalsDocument.maximumTerminalCount
  }

  /// Whether the user can see this terminal now.
  func isSeen(_ terminal: DrawerTerminal) -> Bool {
    isOnScreen && isVisible && terminal.id == activeTerminalID
  }

  /// What the status bar's button says about the terminals nobody is looking at.
  public var attention: DrawerAttention {
    let unseen = terminals.filter { !isSeen($0) }
    if unseen.contains(where: \.hasUnseenExit) { return .ended }
    if unseen.contains(where: \.hasUnseenOutput) { return .output }
    return .none
  }

  /// The terminal the status bar's button names for VoiceOver, when one has news.
  public var noticeTerminal: DrawerTerminal? {
    let unseen = terminals.filter { !isSeen($0) }
    return unseen.first(where: \.hasUnseenExit) ?? unseen.first(where: \.hasUnseenOutput)
  }

  // MARK: - Showing

  /// Reads what was written down, once. Nothing is started.
  func load() async {
    guard !isLoaded else { return }
    isLoaded = true
    guard let document = await dependencies.store.load(sessionID) else { return }
    isVisible = document.isVisible
    height = document.height
    activeTerminalID = document.activeTerminal
    pending = document.terminals.isEmpty ? nil : document
  }

  public func toggle() async {
    if isVisible, !terminals.isEmpty {
      hide()
    } else {
      await show()
    }
  }

  /// Shows the drawer, with its tabs as they were, or a first one in the session's folder.
  public func show() async {
    await load()
    await restore()
    if terminals.isEmpty {
      await newTerminal()
      return
    }
    isVisible = true
    markActiveSeen()
    requestFocus()
    saveSoon()
  }

  /// Hides the drawer. Nothing is stopped: its shells go on running, and their output is kept.
  public func hide() {
    guard isVisible else { return }
    isVisible = false
    saveSoon()
  }

  /// Hands the keyboard to the terminal in front, once it is on screen.
  public func requestFocus() {
    activeTerminal?.pane.requestFocus()
  }

  // MARK: - Tabs

  /// A new tab, with a new shell in the session's folder.
  public func newTerminal() async {
    await load()
    await restore()
    guard canAddTerminal else { return }
    let folder = await dependencies.sessionFolder(sessionID)
    let (directory, fallback) = await DrawerRestoration.directory(
      remembered: nil, sessionFolder: folder, probe: dependencies.probe)
    let terminal = makeTerminal(id: TerminalID(), size: nil)
    terminal.currentDirectory = directory
    terminals.append(terminal)
    activeTerminalID = terminal.id
    isVisible = true
    requestFocus()
    saveSoon()
    if let fallback {
      terminal.pane.post(notice: DrawerRestoration.fallbackNotice(fallback))
    }
    await start(terminal, in: directory, size: nil)
    dependencies.diagnostics.record(
      .session, .info, "drawer.terminalOpened",
      [
        "session": dependencies.diagnostics.pseudonym(sessionID),
        "terminals": .count(terminals.count),
      ])
  }

  public func activate(_ id: TerminalID) {
    guard terminals.contains(where: { $0.id == id }) else { return }
    activeTerminalID = id
    markActiveSeen()
    if let terminal = activeTerminal { scheduleInspection(of: terminal, after: .zero) }
    requestFocus()
    saveSoon()
  }

  /// The tab after (or before) the one in front, round the end.
  public func activateNeighbour(offset: Int) {
    guard terminals.count > 1,
      let index = terminals.firstIndex(where: { $0.id == activeTerminalID })
    else { return }
    let next = (index + offset % terminals.count + terminals.count) % terminals.count
    activate(terminals[next].id)
  }

  /// Moves a tab, by drag or from its menu.
  public func move(_ id: TerminalID, to destination: Int) {
    guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
    let terminal = terminals.remove(at: index)
    terminals.insert(terminal, at: min(max(destination, 0), terminals.count))
    saveSoon()
  }

  /// Names a tab; an empty name gives it back its automatic title.
  public func rename(_ id: TerminalID, to name: String) {
    guard let terminal = terminals.first(where: { $0.id == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    terminal.customTitle = trimmed.isEmpty ? nil : trimmed
    saveSoon()
  }

  /// Follows the handle while it is dragged; written down when it is let go.
  public func setHeight(_ value: Double) {
    height = min(
      max(value, SessionTerminalsDocument.heightRange.lowerBound),
      SessionTerminalsDocument.heightRange.upperBound)
    saveSoon()
  }

  /// Closes a tab for good: its shell and whatever runs in it are stopped, its history erased.
  /// The caller asks first when a command runs (`isRunningCommand`).
  public func close(_ id: TerminalID) async {
    guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
    let terminal = terminals.remove(at: index)
    terminal.isEnding = true
    terminal.cancelTasks()
    if activeTerminalID == id {
      activeTerminalID = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)].id
      markActiveSeen()
    }
    if terminals.isEmpty {
      isVisible = false
    }
    saveSoon()
    await terminal.pane.stop(gracePeriod: Self.stopGracePeriod)
    await dependencies.recorder?.auxiliaryStopped(id)
    await dependencies.store.removeScrollback(of: id, in: sessionID)
    dependencies.diagnostics.record(
      .session, .info, "drawer.terminalClosed",
      [
        "session": dependencies.diagnostics.pseudonym(sessionID),
        "terminals": .count(terminals.count),
      ])
  }

  /// Starts a new shell in a tab whose shell ended, under what it showed.
  public func relaunch(_ id: TerminalID) async {
    guard let terminal = terminals.first(where: { $0.id == id }), !terminal.isRunning else {
      return
    }
    terminal.hasUnseenExit = false
    let folder = await dependencies.sessionFolder(sessionID)
    let (directory, fallback) = await DrawerRestoration.directory(
      remembered: terminal.currentDirectory, sessionFolder: folder, probe: dependencies.probe)
    terminal.currentDirectory = directory
    terminal.pane.post(
      notice: DrawerRestoration.notice(
        scrollback: nil, resumption: .relaunched, at: dependencies.clock.now(),
        fallback: fallback))
    await start(terminal, in: directory, size: terminal.pane.viewportSize)
  }

  // MARK: - Restoring and stopping

  /// Rebuilds the tabs written down: each one takes back its shell if the terminal host kept it
  /// running, and otherwise gets a new one, in the folder it was in, under the history it showed.
  func restore() async {
    guard let document = pending, !isRestoring else { return }
    isRestoring = true
    pending = nil
    defer { isRestoring = false }
    let folder = await dependencies.sessionFolder(sessionID)
    let now = dependencies.clock.now()
    var restored: [DrawerTerminal] = []
    for record in document.terminals.prefix(SessionTerminalsDocument.maximumTerminalCount) {
      let terminal = makeTerminal(id: record.id, size: record.size)
      terminal.customTitle = record.title
      terminal.lastSeenTitle = record.lastSeenTitle
      terminal.currentDirectory = record.directory
      restored.append(terminal)
    }
    terminals = restored
    if activeTerminalID == nil || !terminals.contains(where: { $0.id == activeTerminalID }) {
      activeTerminalID = terminals.first?.id
    }
    for (terminal, record) in zip(restored, document.terminals) {
      await bringBack(terminal, record: record, folder: folder, at: now)
    }
    dependencies.diagnostics.record(
      .session, .info, "drawer.restored",
      [
        "session": dependencies.diagnostics.pseudonym(sessionID),
        "terminals": .count(terminals.count),
      ])
  }

  private func bringBack(
    _ terminal: DrawerTerminal, record: DrawerTerminalRecord, folder: String?, at date: Date
  ) async {
    var scrollback: [UInt8]?
    if let kept = await dependencies.supervisor.session(for: terminal.id) {
      let state = await kept.state()
      if !state.isFinished {
        // Left running with its session's agent: taken back as it is, nothing started or typed.
        await terminal.pane.adopt(kept)
        await running(terminal)
        return
      }
      // Ended while the application was closed: what the host kept of it is fresher than disk.
      scrollback = await kept.history().bytes
    }
    if scrollback == nil, dependencies.preferences.keepsScrollback {
      scrollback = await dependencies.store.loadScrollback(of: terminal.id, in: sessionID)
    }
    let (directory, fallback) = await DrawerRestoration.directory(
      remembered: record.directory, sessionFolder: folder, probe: dependencies.probe)
    terminal.currentDirectory = directory
    terminal.pane.post(
      notice: DrawerRestoration.notice(
        scrollback: scrollback, resumption: .resumed, at: date, fallback: fallback))
    await start(terminal, in: directory, size: record.size)
  }

  /// Writes down what each tab shows, then stops them all: the session is closing. The drawer
  /// comes back as it was when the session is reopened.
  func shutDown() async {
    guard !terminals.isEmpty else {
      await flush()
      return
    }
    let stopping = terminals
    for terminal in stopping {
      terminal.isEnding = true
      terminal.cancelTasks()
    }
    await snapshotAll(stopping)
    await flush()
    // Side by side: each stop may wait out its grace period, and a session with four tabs must
    // not take four times as long to close.
    let stops = stopping.map { terminal in
      Task { await terminal.pane.stop(gracePeriod: Self.stopGracePeriod) }
    }
    for stop in stops { await stop.value }
    for terminal in stopping {
      await dependencies.recorder?.auxiliaryStopped(terminal.id)
    }
    // Rebuilt from the document when the session is reopened.
    pending = document()
    terminals = []
  }

  /// Writes down what each tab shows and lets go of them, running: the application is quitting
  /// and leaves them in the terminal host with their session's agent.
  func handOff() async {
    for terminal in terminals {
      terminal.cancelTasks()
    }
    await snapshotAll(terminals)
    await flush()
  }

  // MARK: - Writing down

  func document() -> SessionTerminalsDocument {
    if let pending, terminals.isEmpty {
      var document = pending
      document.isVisible = isVisible
      document.height = height
      return document
    }
    return SessionTerminalsDocument(
      isVisible: isVisible && !terminals.isEmpty,
      height: height,
      activeTerminal: activeTerminalID,
      terminals: terminals.map { terminal in
        DrawerTerminalRecord(
          id: terminal.id,
          title: terminal.customTitle,
          directory: terminal.currentDirectory,
          size: terminal.pane.viewportSize,
          lastSeenTitle: terminal.title)
      })
  }

  /// Written a moment later, so that a burst of changes — a drag of the handle, a `cd` after
  /// another — is one write.
  func saveSoon() {
    saveTask?.cancel()
    let delay = dependencies.timing.saveDelay
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      await self.flush()
    }
  }

  /// Written now: the session is closing, or the application quitting.
  func flush() async {
    saveTask?.cancel()
    saveTask = nil
    guard isLoaded else { return }
    await dependencies.store.save(document(), for: sessionID)
  }

  func snapshotAll(_ terminals: [DrawerTerminal]) async {
    for terminal in terminals {
      await snapshot(terminal)
    }
  }

  private func snapshot(_ terminal: DrawerTerminal) async {
    guard dependencies.preferences.keepsScrollback, let session = terminal.pane.session else {
      return
    }
    let bytes = await session.history().bytes
    await dependencies.store.saveScrollback(bytes, of: terminal.id, in: sessionID)
    terminal.lastSnapshotAt = .now
  }

  // MARK: - Following a terminal

  private func makeTerminal(id: TerminalID, size: TerminalSize?) -> DrawerTerminal {
    let pane = TerminalPaneModel(
      terminalID: id, supervisor: dependencies.supervisor, spec: nil,
      viewportTimeout: dependencies.viewportTimeout)
    let terminal = DrawerTerminal(id: id, pane: pane)
    pane.onReportedDirectory = { [weak self, weak terminal] path in
      guard let terminal, terminal.currentDirectory != path else { return }
      terminal.currentDirectory = path
      self?.saveSoon()
    }
    return terminal
  }

  private func start(_ terminal: DrawerTerminal, in directory: String, size: TerminalSize?)
    async
  {
    terminal.isEnding = false
    let spec = TerminalSpec.loginShell(
      workingDirectoryURL: URL(fileURLWithPath: directory, isDirectory: true),
      size: size ?? .default, role: .auxiliary)
    await terminal.pane.start(spec: spec)
    guard terminal.pane.session != nil else { return }
    await running(terminal)
  }

  /// Arms what follows a running shell: its record, its output, its end.
  private func running(_ terminal: DrawerTerminal) async {
    guard let session = terminal.pane.session else { return }
    if case .running(let processIdentifier) = await session.state() {
      await dependencies.recorder?.auxiliaryStarted(
        terminal.id, of: sessionID, processGroup: processIdentifier)
    }
    follow(terminal, session: session)
    scheduleInspection(of: terminal, after: .zero)
  }

  private func follow(_ terminal: DrawerTerminal, session: any TerminalSession) {
    terminal.watch?.cancel()
    terminal.watch = Task { [weak self, weak terminal] in
      let attachment = await session.attach()
      var finalState = attachment.state
      if !finalState.isFinished {
        for await event in attachment.events {
          guard !Task.isCancelled, let self, let terminal else { return }
          switch event {
          case .output:
            self.outputArrived(in: terminal)
          case .stateChanged(let state) where state.isFinished:
            finalState = state
          case .stateChanged, .historyTruncated:
            break
          }
          if finalState.isFinished { break }
        }
      }
      if !finalState.isFinished { finalState = await session.state() }
      guard !Task.isCancelled, let self, let terminal else { return }
      await self.shellEnded(in: terminal, state: finalState)
    }
  }

  private func outputArrived(in terminal: DrawerTerminal) {
    if !isSeen(terminal) { terminal.hasUnseenOutput = true }
    scheduleInspection(of: terminal, after: dependencies.timing.inspectionInterval)
    scheduleSnapshot(of: terminal)
  }

  /// `exit` at the prompt closes the tab, as Terminal.app does by default; a shell that ended any
  /// other way leaves its tab, with its status, Restart and Close.
  private func shellEnded(in terminal: DrawerTerminal, state: TerminalProcessState) async {
    guard !terminal.isEnding, terminals.contains(where: { $0 === terminal }) else { return }
    terminal.inspection?.cancel()
    terminal.foregroundCommand = nil
    await dependencies.recorder?.auxiliaryStopped(terminal.id)
    if case .exited(code: 0) = state {
      await close(terminal.id)
      return
    }
    if !isSeen(terminal) { terminal.hasUnseenExit = true }
    await snapshot(terminal)
  }

  private func scheduleInspection(of terminal: DrawerTerminal, after delay: Duration) {
    guard terminal.inspection == nil else { return }
    terminal.inspection = Task { [weak self, weak terminal] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      guard !Task.isCancelled, let self, let terminal else { return }
      await self.inspect(terminal)
      terminal.inspection = nil
    }
  }

  private func inspect(_ terminal: DrawerTerminal) async {
    guard let session = terminal.pane.session,
      case .running(let processIdentifier) = await session.state(),
      let snapshot = await dependencies.inspector.inspect(processIdentifier: processIdentifier)
    else { return }
    if let directory = snapshot.currentDirectory, directory != terminal.currentDirectory {
      terminal.currentDirectory = directory
      saveSoon()
    }
    if terminal.foregroundCommand != snapshot.foregroundCommand {
      terminal.foregroundCommand = snapshot.foregroundCommand
    }
  }

  /// A while after output, and no more often than the interval: a crash then loses at most that
  /// much of what a terminal showed.
  private func scheduleSnapshot(of terminal: DrawerTerminal) {
    guard dependencies.preferences.keepsScrollback, terminal.snapshot == nil else { return }
    let timing = dependencies.timing
    var wait = timing.snapshotDelay
    if let last = terminal.lastSnapshotAt {
      let earliest = last + timing.snapshotInterval
      wait = max(wait, earliest - .now)
    }
    terminal.snapshot = Task { [weak self, weak terminal] in
      try? await Task.sleep(for: wait)
      guard !Task.isCancelled, let self, let terminal else { return }
      await self.snapshot(terminal)
      terminal.snapshot = nil
    }
  }

  private func markActiveSeen() {
    guard let terminal = activeTerminal, isSeen(terminal) else { return }
    terminal.hasUnseenOutput = false
    terminal.hasUnseenExit = false
  }
}

/// Every session's drawer, and what they share: the terminal host, the store, the kernel.
@MainActor
@Observable
public final class SessionTerminals: SessionSideTerminals {
  /// How often a drawer writes, reads its shells and keeps their history.
  public struct Timing: Sendable {
    public var saveDelay: Duration
    public var inspectionInterval: Duration
    public var snapshotDelay: Duration
    public var snapshotInterval: Duration

    public init(
      saveDelay: Duration = .milliseconds(500),
      inspectionInterval: Duration = .milliseconds(500),
      snapshotDelay: Duration = .seconds(2),
      snapshotInterval: Duration = .seconds(15)
    ) {
      self.saveDelay = saveDelay
      self.inspectionInterval = inspectionInterval
      self.snapshotDelay = snapshotDelay
      self.snapshotInterval = snapshotInterval
    }
  }

  /// Not observed: a drawer is made the first time a view asks for it, during its body, where
  /// changing observed state is not allowed. Each drawer is observable on its own.
  @ObservationIgnored private var drawers: [SessionID: SessionTerminalDrawer] = [:]
  @ObservationIgnored private let dependencies: DrawerDependencies
  /// Whether the side terminals' history is kept on disk (ADR 0027).
  public private(set) var keepsScrollback: Bool

  public init(
    supervisor: any TerminalSupervisor,
    store: any SessionTerminalsStore = InMemorySessionTerminalsStore(),
    inspector: any ShellProcessInspector = NoShellInspection(),
    probe: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    recorder: SessionRuntimeRecorder? = nil,
    preferences: any TerminalPreferences = InMemoryTerminalPreferences(),
    clock: any SessionClock = SystemSessionClock(),
    diagnostics: Diagnostics = .disabled,
    viewportTimeout: Duration = .milliseconds(500),
    timing: Timing = Timing(),
    sessionFolder: @escaping @MainActor (SessionID) async -> String?
  ) {
    dependencies = DrawerDependencies(
      supervisor: supervisor, store: store, inspector: inspector, probe: probe,
      recorder: recorder, preferences: preferences, clock: clock, diagnostics: diagnostics,
      sessionFolder: sessionFolder, viewportTimeout: viewportTimeout, timing: timing)
    keepsScrollback = preferences.keepsScrollback
  }

  /// The session's drawer, made at the first use. Nothing is read or started by asking.
  public func drawer(for id: SessionID) -> SessionTerminalDrawer {
    if let drawer = drawers[id] { return drawer }
    let drawer = SessionTerminalDrawer(sessionID: id, dependencies: dependencies)
    drawers[id] = drawer
    return drawer
  }

  public func existingDrawer(for id: SessionID) -> SessionTerminalDrawer? {
    drawers[id]
  }

  /// Reads the drawer of a session being shown, so that its button counts its tabs and a drawer
  /// left open comes back open.
  public func prepare(_ id: SessionID) async {
    let drawer = drawer(for: id)
    await drawer.load()
    if drawer.isVisible { await drawer.restore() }
  }

  /// Turns keeping the history on or off. Off, every history already written is erased.
  public func setKeepsScrollback(_ keeps: Bool) async {
    keepsScrollback = keeps
    dependencies.preferences.keepsScrollback = keeps
    if !keeps { await dependencies.store.removeAllScrollback() }
  }

  /// What the histories weigh on disk, for the diagnostics.
  public func scrollbackByteCount() async -> Int {
    await dependencies.store.scrollbackByteCount()
  }

  /// Writes every drawer down, before the application quits.
  public func flush() async {
    for drawer in drawers.values {
      await drawer.flush()
    }
  }

  // MARK: - SessionSideTerminals

  public func sessionStarted(_ id: SessionID) async {
    await prepare(id)
  }

  public func sessionAdopted(_ id: SessionID) async {
    let drawer = drawer(for: id)
    await drawer.load()
    // Taken back at once, shown or not: a shell left running that nobody took back would not be
    // written down as running, and the next quit would let it go.
    await drawer.restore()
  }

  public func shutDown(_ id: SessionID) async {
    guard let drawer = drawers[id] else { return }
    await drawer.shutDown()
  }

  public func handOff(_ id: SessionID) async {
    guard let drawer = drawers[id] else { return }
    await drawer.handOff()
  }
}
