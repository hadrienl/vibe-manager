import SwiftTerm
import SwiftUI
import VibeApplication
import VibeDomain

/// The terminal view, mounted before the process exists.
///
/// It has to be: its own layout is what tells the pane how many columns and rows the agent will
/// be started with. Until a session appears it simply has nothing to display.
public struct TerminalSurface: NSViewRepresentable {
  private let pane: TerminalPaneModel
  private let session: (any TerminalSession)?
  /// Panes that are not on screen stay mounted, so they must not keep the keyboard.
  private let isActive: Bool
  /// See `TerminalPaneModel.focusRequest`.
  private let focusRequest: Int
  /// What VoiceOver calls the terminal: see `AccessibleTerminalView`.
  private let accessibilityTitle: String?
  /// Whether becoming the terminal on screen takes the keyboard. A side terminal of the drawer
  /// (#43) does not: shown with its session, it would take the keyboard from the agent's terminal.
  /// It takes it when asked to, through `focusRequest`.
  private let claimsKeyboardOnActivation: Bool

  public init(
    pane: TerminalPaneModel,
    session: (any TerminalSession)?,
    isActive: Bool = true,
    focusRequest: Int = 0,
    accessibilityTitle: String? = nil,
    claimsKeyboardOnActivation: Bool = true
  ) {
    self.pane = pane
    self.session = session
    self.isActive = isActive
    self.focusRequest = focusRequest
    self.accessibilityTitle = accessibilityTitle
    self.claimsKeyboardOnActivation = claimsKeyboardOnActivation
  }

  public func makeCoordinator() -> TerminalSurfaceCoordinator {
    TerminalSurfaceCoordinator(pane: pane)
  }

  public func makeNSView(context: Context) -> TerminalView {
    let view = AccessibleTerminalView()
    if let accessibilityTitle {
      view.accessibilityTitle = accessibilityTitle
    }
    view.setAccessibilityIdentifier("terminal")
    // As long as the history the application keeps: at SwiftTerm's default of 500 lines, a history
    // replayed after a relaunch was cut on screen. Measured at about 17 MB for a full terminal of
    // 120 columns, which three sessions afford within the memory budget (#19).
    view.getTerminal().changeScrollback(TerminalScrollbackLimits.default.maximumLineCount)
    view.terminalDelegate = context.coordinator
    view.configureNativeColors()
    let coordinator = context.coordinator
    view.onWindowChange = { [weak coordinator, weak view] in
      guard let coordinator, let view else { return }
      coordinator.observeKeyboardFocus(of: view)
    }
    context.coordinator.bind(to: view)
    return view
  }

  public func updateNSView(_ nsView: TerminalView, context: Context) {
    // The pane can be replaced under a view SwiftUI keeps identical — a relaunch of the same
    // session builds a new one — so the coordinator is told which pane is the live one.
    context.coordinator.adopt(pane: pane)
    if let accessibilityTitle {
      (nsView as? AccessibleTerminalView)?.accessibilityTitle = accessibilityTitle
    }
    if let session {
      context.coordinator.attachIfNeeded(to: session)
    }
    context.coordinator.followActivation(
      isActive, claimingKeyboard: claimsKeyboardOnActivation, in: nsView)
    context.coordinator.followFocusRequest(
      focusRequest, isActive: isActive, claimingOnFirstSight: claimsKeyboardOnActivation,
      in: nsView)
    context.coordinator.observeKeyboardFocus(of: nsView)
  }

  public static func dismantleNSView(
    _ nsView: TerminalView,
    coordinator: TerminalSurfaceCoordinator
  ) {
    coordinator.unbind()
  }
}

private enum TerminalCommand: Sendable {
  case write([UInt8])
  case resize(TerminalSize)
}

@MainActor
public final class TerminalSurfaceCoordinator: NSObject, TerminalViewDelegate {
  private var pane: TerminalPaneModel
  private weak var view: TerminalView?
  private var eventTask: Task<Void, Never>?
  // Object identity, not `session.id`: the id belongs to the work session and is reused by every
  // process started for it, so it cannot tell a restarted session from the one already attached.
  private var attachedSession: ObjectIdentifier?
  /// Whether the view shows anything yet: a prelude fed over what it shows starts it over.
  private var hasFed = false
  private var wasActive: Bool?
  private var lastFocusRequest: Int?
  private var focusObservation: NSKeyValueObservation?
  private weak var observedWindow: NSWindow?
  private let commands: AsyncStream<TerminalCommand>.Continuation
  /// On while a restored history is fed to the view (#43). The programs that wrote it asked the
  /// terminal questions — its attributes, the cursor's position, its colours — and the view
  /// answers them as it reads them: sent on, those answers would reach the new shell's prompt as
  /// keystrokes. A folder the history names (OSC 7) is not where the new shell is either.
  private let replay = ReplayGate()
  private var commandTask: Task<Void, Never>?

  /// How long a view put away is still fed before it is suspended (#248): long enough for a look at
  /// the next session and back to cost nothing, as when stepping through them with ⌥⌘↓.
  static let defaultSuspensionDelay = Duration.seconds(5)
  /// Output is caught up with in slices this size — about ten milliseconds of parsing each — so the
  /// keyboard and the other views are served between two.
  static let catchUpSliceSize = 64 * 1_024
  /// Past this, the pane says the terminal is catching up rather than show it fast-forwarding.
  static let catchUpNoticeDelay = Duration.milliseconds(150)

  private let suspensionDelay: Duration
  /// The process the view shows.
  private var session: (any TerminalSession)?
  /// How far into that process's stream of output the view has been fed: `nil` until it has.
  private var fedThrough: Int?
  /// A view put away for longer than `suspensionDelay` is fed nothing (#248). Parsing the output of
  /// every busy agent behind the visible one was the main actor's largest cost, and a view nobody
  /// looks at has no use for it. It catches up from the session's history when it comes back.
  private(set) var isSuspended = false
  private var suspension: Task<Void, Never>?
  /// Watches a suspended view's output for the questions the view must answer at once.
  private var sentinel: Task<Void, Never>?
  /// The catch-up the sentinel asked for, and whether it asked again meanwhile.
  private var wake: Task<Void, Never>?
  private var wakesAgain = false
  /// The live feed a suspension cancelled, which may still be finishing a slice: whatever feeds the
  /// view next waits for it, so that two feeds never interleave.
  private var retiredFeed: Task<Void, Never>?
  /// How many times the sentinel woke a suspended view, for the tests.
  private(set) var sentinelWakeCount = 0
  /// A process replaced before the view was fed all its output — suspended, or its live feed
  /// cancelled mid-stream — and how far it had been fed: the rest is shown before the next one.
  private var unfinished: (session: any TerminalSession, fedThrough: Int)?
  /// The screen is missing output — the history let go of it, or the live feed dropped it — and is
  /// drawn again from the history before anything else is fed.
  private var needsRepaint = false
  /// A question the view was fed only the start of ends after the place it stopped: the sentinel
  /// starts reading a little before, so the question is not taken for text.
  static let sentinelLookBehind = 32

  init(pane: TerminalPaneModel, suspensionDelay: Duration = defaultSuspensionDelay) {
    self.pane = pane
    self.suspensionDelay = suspensionDelay

    var continuation: AsyncStream<TerminalCommand>.Continuation?
    let stream = AsyncStream<TerminalCommand> { continuation = $0 }
    guard let continuation else {
      preconditionFailure("AsyncStream did not provide a continuation")
    }
    commands = continuation
    super.init()
    // One consumer, one order: keystrokes and resizes reach the process in the order the user
    // made them, and a size measured before the process exists is remembered rather than lost.
    commandTask = Task { @MainActor [weak self] in
      for await command in stream {
        // Read the pane on each command rather than capturing it: `adopt` can have replaced it.
        guard let pane = self?.pane else { continue }
        switch command {
        case .write(let bytes):
          await pane.write(bytes)
        case .resize(let size):
          await pane.reportViewportSize(size)
        }
      }
    }
  }

  deinit {
    commands.finish()
    commandTask?.cancel()
    suspension?.cancel()
    sentinel?.cancel()
    wake?.cancel()
  }

  func bind(to view: TerminalView) {
    if self.view !== view { hasFed = false }
    self.view = view
    connectPasteMode()
    connectLinkMenu()
  }

  /// A link's menu opens through the pane, as a click does, and offers the web view when the
  /// session has one (#186).
  private func connectLinkMenu() {
    guard let view = view as? AccessibleTerminalView else { return }
    view.openLinkFromMenu = { [weak self] link, gesture in
      self?.pane.openLink(link, gesture: gesture)
    }
    view.hasWebView = { [weak self] in self?.pane.hasWebView() ?? false }
  }

  /// Whether the program in the terminal asked for bracketed pastes: known to the view alone, and
  /// read by the pane when a drop types into it (#42).
  private func connectPasteMode() {
    pane.isBracketedPasteEnabled = { [weak view] in
      view?.getTerminal().bracketedPasteMode ?? false
    }
  }

  /// Points the coordinator at the pane the view now renders.
  ///
  /// A relaunch replaces the pane while SwiftUI keeps the same view identity, so without this the
  /// coordinator would keep writing keystrokes and viewport sizes into a discarded model.
  func adopt(pane: TerminalPaneModel) {
    guard self.pane !== pane else { return }
    self.pane = pane
    connectPasteMode()
    connectLinkMenu()
    eventTask?.cancel()
    eventTask = nil
    rememberUnfinished()
    attachedSession = nil
    session = nil
    fedThrough = nil
    needsRepaint = false
    stopSuspension()
  }

  /// Keystrokes must reach the terminal the user is looking at, and only that one: a hidden pane
  /// that kept the first responder would quietly receive what was typed for its neighbour.
  ///
  /// Only a *change* of activation moves the keyboard. Claiming it on every update would fight
  /// the user for it: the surrounding view redraws whenever a pane's status changes, and the
  /// active terminal would steal the focus back from the sidebar mid-keystroke.
  func followActivation(_ isActive: Bool, claimingKeyboard: Bool = true, in view: TerminalView) {
    // Every pane stays mounted, and a pane at zero opacity is still drawn: each busy agent behind
    // the visible one repainted its whole screen on the main thread at every spinner frame, and the
    // terminal being typed in waited behind them for its echo. A hidden view is not drawn at all.
    // Its output is still fed, so it is up to date when it comes back, and redrawn whole then.
    //
    // The keyboard moves between the two: shown before it can take the keyboard, and hidden only
    // once it has let go of it. Hiding the first responder makes AppKit hand the keyboard to the
    // next key view — a sidebar field or a button that would then receive what was typed.
    if isActive, view.isHidden {
      view.isHidden = false
      view.needsDisplay = true
    }
    moveKeyboard(following: isActive, claimingKeyboard: claimingKeyboard, in: view)
    if !isActive, !view.isHidden {
      view.isHidden = true
    }
    // Hidden, it is still fed for a while, then suspended; shown, it catches up (#248).
    if isActive {
      resumeIfSuspended()
    } else {
      scheduleSuspension()
    }
  }

  private func moveKeyboard(
    following isActive: Bool, claimingKeyboard: Bool, in view: TerminalView
  ) {
    // No window yet: nothing can hold the keyboard, and this is not the change we are waiting
    // for — leave the state untouched so the next update still acts on it.
    guard let window = view.window else { return }
    guard wasActive != isActive else { return }
    wasActive = isActive

    if isActive {
      if claimingKeyboard { window.makeFirstResponder(view) }
    } else if window.firstResponder === view {
      window.makeFirstResponder(nil)
    }
  }

  /// Takes the keyboard when asked to, and only when this terminal is the one on screen. Like
  /// activation, only a *new* request moves it: a redraw must not steal the focus back.
  ///
  /// The first request a view sees was made before it existed. A pane that claims the keyboard
  /// on activation takes it then, as it always has; one that does not — a side terminal — takes
  /// it only if the request is still waiting to be honoured, not for having been asked once long
  /// ago, before its session was last put away.
  func followFocusRequest(
    _ request: Int, isActive: Bool, claimingOnFirstSight: Bool = true, in view: TerminalView
  ) {
    guard let window = view.window else { return }
    guard lastFocusRequest != request else { return }
    let isFirstSight = lastFocusRequest == nil
    lastFocusRequest = request
    let isWaiting = pane.takePendingFocusRequest()
    if isFirstSight, !claimingOnFirstSight, !isWaiting { return }
    if isActive { window.makeFirstResponder(view) }
  }

  /// Tells the pane whether its view holds the keyboard, from the window's first responder.
  func observeKeyboardFocus(of view: TerminalView) {
    guard let window = view.window, observedWindow !== window else { return }
    observedWindow = window
    // Compared by identity: the view itself cannot cross into the observation's closure.
    let target = ObjectIdentifier(view)
    focusObservation = window.observe(\.firstResponder, options: [.initial, .new]) {
      [weak self] window, _ in
      MainActor.assumeIsolated {
        let responder = window.firstResponder.map(ObjectIdentifier.init)
        self?.pane.setKeyboardFocus(responder == target)
      }
    }
  }

  func attachIfNeeded(to session: any TerminalSession) {
    let identity = ObjectIdentifier(session)
    guard attachedSession != identity else { return }
    attachedSession = identity
    rememberUnfinished()
    self.session = session
    fedThrough = nil
    needsRepaint = false
    // A new process is fed from its start, suspended or not: a hidden view is suspended again
    // once it has been put away for long enough.
    stopSuspension()
    startFeeding(session)
  }

  /// A relaunch replaces the process while its view was suspended, or still being fed: what the
  /// old one wrote after that point — its last answer, its error — is shown before the new one.
  private func rememberUnfinished() {
    guard let session, let fedThrough else { return }
    unfinished = (session, fedThrough)
  }

  func unbind() {
    eventTask?.cancel()
    eventTask = nil
    attachedSession = nil
    session = nil
    fedThrough = nil
    unfinished = nil
    needsRepaint = false
    stopSuspension()
    focusObservation = nil
    observedWindow = nil
    pane.setKeyboardFocus(false)
    view = nil
  }

  /// Feeds the view the session's output: from its start the first time, from where it stopped
  /// after a suspension, then live. `previous` is a catch-up still finishing its slice, waited for
  /// so that two feeds never interleave.
  private func startFeeding(
    _ session: any TerminalSession, after previous: Task<Void, Never>? = nil
  ) {
    eventTask?.cancel()
    let retired = retiredFeed
    retiredFeed = nil
    let unfinished = self.unfinished
    self.unfinished = nil
    eventTask = Task { [session] in
      await retired?.value
      await previous?.value
      if let unfinished {
        let history = await unfinished.session.history()
        guard !Task.isCancelled else { return }
        await finishShowing(history, after: unfinished.fedThrough)
      }
      let attachment = await session.attach()
      guard !Task.isCancelled else { return }
      await bringUpToDate(session, with: attachment.history)
      // Hidden when it came back from a suspension, until it showed what it had missed.
      view?.alphaValue = 1
      for await event in attachment.events {
        guard !Task.isCancelled else { return }
        switch event {
        case .output(let bytes):
          feedOutput(bytes)
        case .outputDropped(let byteCount):
          // The view fell behind and lost those bytes: past them in the stream, but missing from
          // the screen, which is drawn again from the history that still holds them.
          fedThrough = (fedThrough ?? 0) + byteCount
          needsRepaint = true
          startFeeding(session)
          return
        case .stateChanged, .historyTruncated, .outputPulse:
          continue
        }
      }
    }
  }

  /// Shows the end of a process the view had not been fed all of, above the process replacing it.
  /// Nothing it asked is answered: the process that would read the answer is gone.
  private func finishShowing(_ history: TerminalHistorySnapshot, after offset: Int) async {
    if offset < history.startOffset { restartScreen(above: nil) }
    let skipped = min(max(0, offset - history.startOffset), history.bytes.count)
    await feedInSlices(history.bytes[skipped...], replaying: true)
  }

  /// Feeds what the view has not seen of `history`: all of it, above its prelude, the first time;
  /// only what follows `fedThrough` afterwards.
  private func bringUpToDate(
    _ session: any TerminalSession, with history: TerminalHistorySnapshot
  ) async {
    guard let fedThrough else {
      // Before the history of the new session, and in the same task, so a restart's separator
      // cannot race the first bytes of the process it announces.
      let prelude = pane.prelude(above: session)
      // The prelude holds all this view showed of the previous process — its own prelude and
      // history — so the screen starts over rather than showing it twice.
      if !prelude.isEmpty, hasFed {
        view?.getTerminal().resetToInitialState()
        view?.getTerminal().clearScrollback()
      }
      replay.isOn = true
      feed(pane.takePendingNotice())
      feed(prelude)
      replay.isOn = false
      feed(history.bytes)
      self.fedThrough = history.endOffset
      return
    }
    // The history let go of output the view never saw: going on from the stale screen would show
    // the rest out of place, from the middle of a frame or a sequence. It starts over instead.
    if needsRepaint || fedThrough < history.startOffset {
      needsRepaint = true
      await repaint(session, from: history, knownThrough: fedThrough)
      return
    }
    await catchUp(on: history, after: fedThrough)
  }

  /// Feeds the part of `history` that follows `offset`.
  ///
  /// Every byte fed here is new to the view, so it answers what they ask, as it would have live.
  private func catchUp(on history: TerminalHistorySnapshot, after offset: Int) async {
    let skipped = min(max(0, offset - history.startOffset), history.bytes.count)
    fedThrough = history.startOffset + skipped
    await feedInSlices(history.bytes[skipped...], replaying: false)
  }

  /// Draws the screen again from what the history holds (#248).
  ///
  /// The output up to `offset` already went past the view — answered, or dropped on its way — so
  /// it is replayed without answers. What follows is new, and answered as it would have been live.
  /// Output the history had let go of is lost to the view, as it is to one opened now.
  private func repaint(
    _ session: any TerminalSession, from history: TerminalHistorySnapshot, knownThrough offset: Int
  ) async {
    restartScreen(above: session)
    let known = min(max(0, offset - history.startOffset), history.bytes.count)
    await feedInSlices(history.bytes[..<known], replaying: true)
    guard !Task.isCancelled else { return }
    fedThrough = history.startOffset + known
    await feedInSlices(history.bytes[known...], replaying: false)
    guard !Task.isCancelled else { return }
    needsRepaint = false
  }

  /// An empty screen, under the prelude `session` is shown with, if any.
  private func restartScreen(above session: (any TerminalSession)?) {
    view?.getTerminal().resetToInitialState()
    view?.getTerminal().clearScrollback()
    guard let session else { return }
    replay.isOn = true
    feed(pane.prelude(above: session))
    replay.isOn = false
  }

  /// Feeds `bytes` in slices, so the keyboard and the other views are served between two.
  ///
  /// A long feed is not shown fast-forwarding: the view is drawn once it is done, and the pane
  /// says what is happening if it takes more than a glance — when it is on screen. Replayed bytes
  /// answer nothing and do not move the view's place in the stream.
  private func feedInSlices(_ bytes: ArraySlice<UInt8>, replaying: Bool) async {
    guard !bytes.isEmpty else { return }
    let interval = Signposts.begin("terminal.catchUp")
    defer { Signposts.end("terminal.catchUp", interval) }
    guard bytes.count > Self.catchUpSliceSize else {
      feed(bytes, replaying: replaying)
      return
    }
    view?.alphaValue = 0
    let notice = Task { [weak self] in
      try? await Task.sleep(for: Self.catchUpNoticeDelay)
      guard !Task.isCancelled, let self, self.view?.isHidden == false else { return }
      self.pane.isCatchingUp = true
    }
    defer {
      notice.cancel()
      pane.isCatchingUp = false
      view?.alphaValue = 1
    }
    var remaining = bytes
    while !remaining.isEmpty {
      let slice = remaining.prefix(Self.catchUpSliceSize)
      feed(slice, replaying: replaying)
      remaining = remaining.dropFirst(slice.count)
      guard !remaining.isEmpty else { break }
      await Task.yield()
      guard !Task.isCancelled else { return }
    }
  }

  private func feed(_ bytes: ArraySlice<UInt8>, replaying: Bool) {
    if replaying {
      replay.isOn = true
      feed(Array(bytes))
      replay.isOn = false
    } else {
      feedOutput(Array(bytes))
    }
  }

  // MARK: - Suspension of a view put away (#248)

  private func scheduleSuspension() {
    guard suspension == nil, !isSuspended, session != nil else { return }
    suspension = Task { [weak self, suspensionDelay] in
      try? await Task.sleep(for: suspensionDelay)
      guard !Task.isCancelled else { return }
      self?.suspend()
    }
  }

  private func suspend() {
    suspension = nil
    guard let session, !isSuspended else { return }
    isSuspended = true
    eventTask?.cancel()
    retiredFeed = eventTask
    eventTask = nil
    watchWhileSuspended(session, from: fedThrough ?? 0)
  }

  private func resumeIfSuspended() {
    suspension?.cancel()
    suspension = nil
    guard isSuspended, let session else { return }
    isSuspended = false
    let finishing = wake
    sentinel?.cancel()
    sentinel = nil
    wake?.cancel()
    wake = nil
    wakesAgain = false
    // Not drawn until it has caught up: the stale screen would flash before the new one.
    view?.alphaValue = 0
    startFeeding(session, after: finishing)
  }

  /// Back to a view fed live, with nothing planned.
  private func stopSuspension() {
    suspension?.cancel()
    suspension = nil
    sentinel?.cancel()
    sentinel = nil
    wake?.cancel()
    wake = nil
    wakesAgain = false
    isSuspended = false
  }

  /// Reads the output of a suspended view off the main actor, for the questions it has to answer
  /// and the folder a shell reports, starting where the view stopped.
  private func watchWhileSuspended(_ session: any TerminalSession, from offset: Int) {
    let from = offset - Self.sentinelLookBehind
    sentinel = Task.detached { [weak self] in
      let attachment = await session.attach()
      var scanner = TerminalQuerySentinel()
      let history = attachment.history
      let skipped = min(max(0, from - history.startOffset), history.bytes.count)
      if let query = scanner.scan(history.bytes[skipped...]) {
        await self?.sentinelSaw(query)
      }
      for await event in attachment.events {
        guard self != nil else { return }
        guard case .output(let bytes) = event, let query = scanner.scan(bytes) else { continue }
        await self?.sentinelSaw(query)
      }
    }
  }

  /// Brings the suspended view up to date without showing it: it answers from the exact state of
  /// its screen, then goes back to being fed nothing.
  private func sentinelSaw(_ query: TerminalQuerySentinel.Query) {
    Signposts.event("terminal.sentinelWake")
    sentinelWakeCount += 1
    guard isSuspended, let session else { return }
    guard wake == nil else {
      wakesAgain = true
      return
    }
    let retired = retiredFeed
    wake = Task { [weak self, session] in
      await retired?.value
      repeat {
        self?.wakesAgain = false
        let attachment = await session.attach()
        guard let self, !Task.isCancelled, self.isSuspended else { return }
        await self.bringUpToDate(session, with: attachment.history)
      } while self?.wakesAgain == true && !Task.isCancelled
      self?.wake = nil
    }
  }

  private func feed(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    hasFed = true
    Signposts.interval("terminal.feed") {
      view?.feed(byteArray: bytes[...])
    }
  }

  /// Feeds output of the process, and moves the view's place in its stream.
  private func feedOutput(_ bytes: [UInt8]) {
    feed(bytes)
    fedThrough = (fedThrough ?? 0) + bytes.count
  }

  nonisolated public func send(source: TerminalView, data: ArraySlice<UInt8>) {
    guard !replay.isOn else { return }
    commands.yield(.write([UInt8](data)))
  }

  nonisolated public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    commands.yield(.resize(TerminalSize(columns: newCols, rows: newRows)))
  }

  nonisolated public func scrolled(source: TerminalView, position: Double) {}

  nonisolated public func setTerminalTitle(source: TerminalView, title: String) {}

  nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard !replay.isOn else { return }
    Task { @MainActor [weak self] in
      self?.pane.reportDirectory(directory)
    }
  }

  nonisolated public func clipboardCopy(source: TerminalView, content: Data) {}

  /// A click on an address (#69, #186): SwiftTerm asks from the release of the mouse, on the main
  /// thread, so the click is the event being handled — whether ⌘ or ⌥ was held is read from it, not
  /// later, when the keys may have been let go, and a double click's second press must find the
  /// first click already waiting.
  nonisolated public func requestOpenLink(
    source: TerminalView,
    link: String,
    params: [String: String]
  ) {
    guard Thread.isMainThread else {
      let alternate = NSEvent.modifierFlags.contains(.option)
      Task { @MainActor [weak self] in
        self?.pane.openLink(link, gesture: .click(alternate: alternate))
      }
      return
    }
    MainActor.assumeIsolated {
      let event = NSApp.currentEvent
      let flags = event?.modifierFlags ?? NSEvent.modifierFlags
      let gesture = LinkGesture.click(alternate: flags.contains(.option))
      let open: @MainActor @Sendable () -> Void = { [weak self] in
        self?.pane.openLink(link, gesture: gesture)
      }
      guard let view = source as? AccessibleTerminalView else {
        open()
        return
      }
      // A plain click on what is not a page does nothing, rather than beep at each click.
      let command = flags.contains(.command)
      guard command || TerminalPaneModel.opensOnClick(link) else { return }
      view.linkClicks.linkClicked(
        clickCount: event?.clickCount ?? 1, command: command, open: open)
    }
  }

  nonisolated public func bell(source: TerminalView) {}

  nonisolated public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

  nonisolated public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A flag the view's delegate reads from the thread SwiftTerm calls it on, which is the one that
/// feeds it, while the surface sets it around a feed.
private final class ReplayGate: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isOn: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}
