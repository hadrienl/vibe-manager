import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

@MainActor
@Observable
public final class TerminalPaneModel {
  public enum Status: Equatable {
    case starting
    case running
    case exited(code: Int32)
    case terminated(signal: Int32)
    case failed(message: String)
  }

  public struct Failure: Equatable {
    public let message: String
    public let suggestion: String?
  }

  public private(set) var status: Status = .starting
  public private(set) var session: (any TerminalSession)?
  public private(set) var failure: Failure?
  /// The error behind `failure`, when the terminal said which: for the diagnostics log, which
  /// records its name and never its message.
  public private(set) var launchError: TerminalError?
  /// The size the surface last measured, in character cells.
  public private(set) var viewportSize: TerminalSize?
  /// Whether this process ended because the application asked it to.
  ///
  /// An agent stopped by Close or Archive is killed, and reports the signal it was killed with —
  /// 143 for a `SIGTERM`. Read as a bare exit code that is an alarming red row about a session
  /// the user closed themselves on purpose.
  public private(set) var wasStoppedOnPurpose = false
  /// Whether anything was ever typed into this process.
  ///
  /// An agent that refused the conversation it was handed exits before a key is pressed. One the
  /// user actually worked in did not refuse anything, whatever it exits with afterwards.
  public private(set) var hasReceivedInput = false
  /// Whether this terminal's view holds the keyboard: ⌘W and ⌃⇥ act on the drawer's tabs while
  /// one of its terminals does (#43).
  public private(set) var hasKeyboardFocus = false

  /// Whether the view is catching up on what its process wrote while it was put away, for longer
  /// than a glance (#248): the pane says so rather than show a terminal fast-forwarding.
  public internal(set) var isCatchingUp = false

  func setKeyboardFocus(_ focused: Bool) {
    guard hasKeyboardFocus != focused else { return }
    hasKeyboardFocus = focused
  }

  /// Bumped to hand the keyboard back to this terminal — from the notes, on Escape. A counter
  /// rather than a flag: the same request twice in a row must still move the focus twice.
  public private(set) var focusRequest = 0

  /// The terminal this pane shows: its session's agent, or one of its side terminals (#43).
  public let terminalID: TerminalID
  private let supervisor: any TerminalSupervisor
  /// What `start()` launches. `nil` for a pane that took over a process it never started — one the
  /// terminal host kept running while the application was closed — until a restart hands it one.
  private var spec: TerminalSpec?
  private let viewportTimeout: Duration
  private var stateTask: Task<Void, Never>?
  private var isStarting = false
  private var viewportWaiters: [ViewportWaiter] = []
  private var pendingNotice: [UInt8] = []
  /// What the next process is shown under, until it starts.
  private var queuedPrelude: [UInt8]?
  /// What the current process is shown under, and which process that is.
  private var boundPrelude: (session: ObjectIdentifier, bytes: [UInt8])?

  public init(
    terminalID: TerminalID,
    supervisor: any TerminalSupervisor,
    spec: TerminalSpec?,
    viewportTimeout: Duration = .milliseconds(500)
  ) {
    self.terminalID = terminalID
    self.supervisor = supervisor
    self.spec = spec
    self.viewportTimeout = viewportTimeout
  }

  /// The pane of a session's agent.
  public convenience init(
    sessionID: SessionID,
    supervisor: any TerminalSupervisor,
    spec: TerminalSpec?,
    viewportTimeout: Duration = .milliseconds(500)
  ) {
    self.init(
      terminalID: sessionID.agentTerminal, supervisor: supervisor, spec: spec,
      viewportTimeout: viewportTimeout)
  }

  /// Asks the surface to take the keyboard, if it is the terminal on screen.
  public func requestFocus() {
    focusRequest += 1
    hasPendingFocusRequest = true
  }

  /// A request made while the view was not there to take it, consumed once. A side terminal
  /// (#43) takes the keyboard on a request only: shown again with its session, it must not take
  /// it from the agent's terminal.
  @ObservationIgnored private var hasPendingFocusRequest = false

  func takePendingFocusRequest() -> Bool {
    defer { hasPendingFocusRequest = false }
    return hasPendingFocusRequest
  }

  /// Starts the process, once the pane knows how big it is.
  ///
  /// A terminal program reads its size when it starts and draws itself around it. Spawning at
  /// 80×24 and resizing a moment later leaves the agent's first screen — its banner, its prompt
  /// box — laid out for a terminal that never existed. The wait is bounded: if no surface has
  /// measured itself by then, the spec's own size is used rather than delaying the launch.
  ///
  /// A restart may carry a new plan — the session's agent, model or folder can have changed — so
  /// a given `spec` replaces the one the pane was built with rather than being ignored.
  public func start(spec: TerminalSpec? = nil) async {
    guard !isStarting, session == nil || !status.isRunning else { return }
    guard spec != nil || self.spec != nil else { return }
    isStarting = true
    defer { isStarting = false }

    if let spec {
      self.spec = spec
    }

    // The pane says it is starting *before* it waits for its size, not after. Waiting can take a
    // layout pass, and a pane that still reported the previous run's exit code for that long read
    // as idle to everything that asks `isRunning` — so a second launch arriving in the window got
    // through, was dropped by the `isStarting` guard above, and then wired itself to the dead
    // terminal this line is about to release.
    stateTask?.cancel()
    stateTask = nil
    session = nil
    status = .starting
    failure = nil
    launchError = nil
    // A new process: whatever ended the previous one says nothing about how this one will end.
    wasStoppedOnPurpose = false
    hasReceivedInput = false

    if viewportSize == nil {
      await waitForViewport()
    }

    guard var launchSpec = self.spec else { return }
    if let viewportSize {
      launchSpec.initialSize = viewportSize
    }

    do {
      let session = try await supervisor.start(launchSpec, for: terminalID)
      bindPrelude(to: session)
      self.session = session
      observe(session)
    } catch let error as TerminalError {
      launchError = error
      failure = Failure(
        message: error.errorDescription ?? Self.notStarted,
        suggestion: error.recoverySuggestion
      )
      status = .failed(message: error.errorDescription ?? Self.notStarted)
    } catch {
      failure = Failure(message: Self.notStarted, suggestion: nil)
      status = .failed(message: Self.notStarted)
    }
  }

  private static var notStarted: String {
    String(localized: "The terminal could not be started.", bundle: .module)
  }

  /// Shows a process this pane did not start: one the terminal host kept running while the
  /// application was closed, or one that ended in the meantime. Nothing is launched and nothing is
  /// sent to it; the surface replays its history and follows it from there.
  public func adopt(_ session: any TerminalSession) async {
    stateTask?.cancel()
    stateTask = nil
    bindPrelude(to: session)
    self.session = session
    failure = nil
    wasStoppedOnPurpose = false
    hasReceivedInput = false
    apply(await session.state())
    observe(session)
  }

  /// Holds a line the application itself writes into the terminal, above the next process.
  ///
  /// It is kept rather than fed straight to the view because the pane is the only thing that
  /// exists at this point in a restart: the surface may not be mounted yet, and the terminal
  /// session the line belongs above has not been started. The surface takes it when it attaches,
  /// so the line always lands before the first byte of the new process and never twice.
  public func post(notice text: String) {
    pendingNotice.append(contentsOf: Array(text.utf8))
  }

  /// The same, as bytes: a side terminal's restored history (#43) is written as it was read, since
  /// decoding it as text would break a sequence its buffer cut in two.
  public func post(notice bytes: [UInt8]) {
    pendingNotice.append(contentsOf: bytes)
  }

  /// The pending notice, handed over once.
  public func takePendingNotice() -> [UInt8] {
    defer { pendingNotice = [] }
    return pendingNotice
  }

  /// Holds what the next process is shown under for as long as it lives: a side terminal's
  /// restored history and its separator (#43).
  ///
  /// Unlike a notice, it is not handed over once. A drawer's view is rebuilt whenever it is hidden
  /// and shown again, or its session is left and come back to, and each new view replays it above
  /// the process's own history — or the tab would show a bare prompt where its past was.
  public func post(prelude bytes: [UInt8]) {
    queuedPrelude = bytes
  }

  /// What `session` is shown under, if it is the process the prelude was posted for.
  public func prelude(above session: any TerminalSession) -> [UInt8] {
    guard let boundPrelude, boundPrelude.session == ObjectIdentifier(session) else { return [] }
    return boundPrelude.bytes
  }

  /// What the current process is shown under.
  public var prelude: [UInt8] {
    session.map { prelude(above: $0) } ?? []
  }

  private func bindPrelude(to session: any TerminalSession) {
    boundPrelude = (ObjectIdentifier(session), queuedPrelude ?? [])
    queuedPrelude = nil
  }

  /// Called by the surface whenever it has measured itself, before and after the process exists.
  public func reportViewportSize(_ size: TerminalSize) async {
    guard size.isUsable else { return }
    let isFirst = viewportSize == nil
    viewportSize = size

    if isFirst {
      let waiters = viewportWaiters
      viewportWaiters = []
      waiters.forEach { $0.resume() }
    }
    await session?.resize(to: size)
  }

  /// A second view of the terminal — the block a panel of the agent opens in its conversation
  /// (#219) — sizes the process to itself while it is on screen, without taking the place of the
  /// size the terminal's own view measured.
  public func reportMirrorViewportSize(_ size: TerminalSize) async {
    guard size.isUsable else { return }
    await session?.resize(to: size)
  }

  /// The mirror is gone: the process is given back the size of the terminal's own view.
  public func restorePrimaryViewportSize() async {
    guard let viewportSize else { return }
    await session?.resize(to: viewportSize)
  }

  /// Told of everything the user types, in the writes it arrives in: the keystroke that answers an
  /// agent's question is how its state is known to have moved before the agent says so (#45).
  @ObservationIgnored public var onUserInput: (([UInt8]) -> Void)?

  /// Told of the folder the shell says it is in (OSC 7), for a side terminal's title (#43). Most
  /// shells say nothing unless configured to, so the folder is also read from the kernel.
  @ObservationIgnored public var onReportedDirectory: ((String) -> Void)?

  func reportDirectory(_ directory: String?) {
    guard let directory, let path = Self.path(fromReportedDirectory: directory) else { return }
    onReportedDirectory?(path)
  }

  /// OSC 7 names a `file://host/path` URL; some shells send a bare path.
  static func path(fromReportedDirectory text: String) -> String? {
    if text.hasPrefix("/") { return text }
    guard let url = URL(string: text), url.isFileURL, !url.path.isEmpty else { return nil }
    return url.path
  }

  /// Told of an address clicked in the terminal, or chosen from its menu, with how (#69, #186).
  /// Unset, the address opens in the default browser, as it would from any terminal — only when it
  /// is a page or a mail address.
  @ObservationIgnored public var onOpenLink: ((URL, LinkGesture) -> Void)?

  /// Whether the session has a web view, for the menu of a link: set with `onOpenLink`.
  @ObservationIgnored public var hasWebView: () -> Bool = { false }

  func openLink(_ text: String, gesture: LinkGesture) {
    guard let url = Self.url(fromLink: text) else { return }
    if let onOpenLink {
      onOpenLink(url, gesture)
    } else {
      Self.openOutside(url)
    }
  }

  /// Where a terminal's link goes when nothing else is told of it: the default browser, or the mail
  /// application, and nothing that is neither a page nor a mail address.
  public static func openOutside(_ url: URL) {
    switch LinkRouting.route(url, gesture: .browser, preference: .defaultBrowser, hasWebView: false)
    {
    case .browser, .system: ExternalOpening.open(url)
    case .refused: NSSound.beep()
    case .webView, .newTab: break
    }
  }

  /// Whether a plain click may open the link: a page or a mail address. Another application's
  /// address still opens with ⌘-click, as it did — refused with a beep when it is not a page.
  static func opensOnClick(_ link: String) -> Bool {
    guard let url = url(fromLink: link) else { return false }
    return LinkRouting.isPage(url) || LinkRouting.isMail(url)
  }

  /// A link as the terminal gives it: an OSC 8 address, or text that looks like one.
  static func url(fromLink text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
    return url
  }

  /// Whether the program running asked for bracketed pastes. Set by the surface, which alone reads
  /// the terminal's modes.
  @ObservationIgnored public var isBracketedPasteEnabled: () -> Bool = { false }

  /// Types what was dropped on the session at the cursor of the program, never followed by Return
  /// (#42), and gives the terminal the keyboard. A user's gesture, so it travels as typing does.
  /// Returns whether anything was written.
  @discardableResult
  public func insert(_ payloads: [DropPayload]) async -> Bool {
    guard status == .running else { return false }
    let bytes = PathInsertion.terminalBytes(for: payloads, bracketed: isBracketedPasteEnabled())
    guard !bytes.isEmpty else { return false }
    await write(bytes)
    requestFocus()
    return true
  }

  /// Input travels through here so that keystrokes and resizes keep the order they were made in.
  public func write(_ bytes: [UInt8]) async {
    guard !bytes.isEmpty else { return }
    hasReceivedInput = true
    onUserInput?(bytes)
    await session?.write(bytes)
  }

  public func stop(gracePeriod: Duration = .seconds(3)) async {
    wasStoppedOnPurpose = true
    await supervisor.stop(id: terminalID, gracePeriod: gracePeriod)
    if let session {
      apply(await session.state())
    }
  }

  private func waitForViewport() async {
    await withCheckedContinuation { continuation in
      let waiter = ViewportWaiter(continuation)
      viewportWaiters.append(waiter)
      Task { [viewportTimeout] in
        try? await Task.sleep(for: viewportTimeout)
        waiter.resume()
      }
    }
  }

  private func observe(_ session: any TerminalSession) {
    stateTask?.cancel()
    stateTask = Task { [weak self] in
      // State changes only: the status is not woken by the output (#248).
      let attachment = await session.attach(.state)
      self?.apply(attachment.state)
      for await event in attachment.events {
        guard case .stateChanged(let state) = event else { continue }
        self?.apply(state)
      }
      guard !Task.isCancelled else { return }
      self?.apply(await session.state())
    }
  }

  private func apply(_ state: TerminalProcessState) {
    switch state {
    case .starting:
      status = .starting
    case .running:
      status = .running
    case .exited(let code):
      status = .exited(code: code)
    case .terminated(let signal):
      status = .terminated(signal: signal)
    case .failed(let error):
      status = .failed(
        message: error.errorDescription
          ?? String(localized: "The terminal failed.", bundle: .module))
    }
  }
}

/// Resumed either by the first measurement or by the deadline, and never twice.
@MainActor
private final class ViewportWaiter {
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
