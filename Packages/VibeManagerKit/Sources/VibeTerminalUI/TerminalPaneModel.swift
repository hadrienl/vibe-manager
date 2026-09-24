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
  /// Bumped to hand the keyboard back to this terminal — from the notes, on Escape. A counter
  /// rather than a flag: the same request twice in a row must still move the focus twice.
  public private(set) var focusRequest = 0

  private let sessionID: SessionID
  private let supervisor: any TerminalSupervisor
  private var spec: TerminalSpec
  private let viewportTimeout: Duration
  private var stateTask: Task<Void, Never>?
  private var isStarting = false
  private var viewportWaiters: [ViewportWaiter] = []
  private var pendingNotice: [UInt8] = []

  public init(
    sessionID: SessionID,
    supervisor: any TerminalSupervisor,
    spec: TerminalSpec,
    viewportTimeout: Duration = .milliseconds(500)
  ) {
    self.sessionID = sessionID
    self.supervisor = supervisor
    self.spec = spec
    self.viewportTimeout = viewportTimeout
  }

  /// Asks the surface to take the keyboard, if it is the terminal on screen.
  public func requestFocus() {
    focusRequest += 1
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
    // A new process: whatever ended the previous one says nothing about how this one will end.
    wasStoppedOnPurpose = false
    hasReceivedInput = false

    if viewportSize == nil {
      await waitForViewport()
    }

    var launchSpec = self.spec
    if let viewportSize {
      launchSpec.initialSize = viewportSize
    }

    do {
      let session = try await supervisor.start(launchSpec, for: sessionID)
      self.session = session
      observe(session)
    } catch let error as TerminalError {
      failure = Failure(
        message: error.errorDescription ?? "The terminal could not be started.",
        suggestion: error.recoverySuggestion
      )
      status = .failed(message: error.errorDescription ?? "The terminal could not be started.")
    } catch {
      failure = Failure(message: "The terminal could not be started.", suggestion: nil)
      status = .failed(message: "The terminal could not be started.")
    }
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

  /// The pending notice, handed over once.
  public func takePendingNotice() -> [UInt8] {
    defer { pendingNotice = [] }
    return pendingNotice
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

  /// Input travels through here so that keystrokes and resizes keep the order they were made in.
  public func write(_ bytes: [UInt8]) async {
    guard !bytes.isEmpty else { return }
    hasReceivedInput = true
    await session?.write(bytes)
  }

  public func stop() async {
    wasStoppedOnPurpose = true
    await supervisor.stop(id: sessionID, gracePeriod: .seconds(3))
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
      let attachment = await session.attach()
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
      status = .failed(message: error.errorDescription ?? "The terminal failed.")
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
