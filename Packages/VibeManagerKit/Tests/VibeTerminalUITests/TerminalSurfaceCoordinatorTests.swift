import AppKit
import Foundation
import SwiftTerm
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminalUI

/// A session that records how many views asked it for its history and its stream.
private actor CountingSession: TerminalSession {
  nonisolated let id: TerminalID
  private(set) var attachCount = 0

  init(id: TerminalID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    attachCount += 1
    return TerminalAttachment(
      state: .running(processIdentifier: 7),
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: AsyncStream { $0.finish() }
    )
  }

  func state() -> TerminalProcessState { .running(processIdentifier: 7) }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}
  func resize(to size: TerminalSize) {}
  func stop(gracePeriod: Duration) {}
  func kill() {}
}

private actor IdleSupervisor: TerminalSupervisor {
  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    CountingSession(id: id)
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { nil }
  func stop(id: TerminalID, gracePeriod: Duration) {}
  func stopAll(gracePeriod: Duration) {}
}

@MainActor
private func makeCoordinator(terminalID: TerminalID) -> TerminalSurfaceCoordinator {
  TerminalSurfaceCoordinator(pane: makePaneModel(terminalID: terminalID))
}

@MainActor
private func makePaneModel(terminalID: TerminalID) -> TerminalPaneModel {
  TerminalPaneModel(
    terminalID: terminalID,
    supervisor: IdleSupervisor(),
    spec: TerminalSpec(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ),
    viewportTimeout: .zero
  )
}

/// Waits for the session to be attached, however long a busy runner takes to get there.
///
/// No deadline of its own: bounded to one second of wall-clock time, it ran out on a CI runner
/// where each of these tests took eight. The time limit of the tests stops an attach that never
/// comes.
private func attachCount(of session: CountingSession) async -> Int {
  while true {
    let count = await session.attachCount
    if count > 0 { return count }
    try? await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
@Test(
  "A restarted session is attached again, although it carries the same session id",
  .timeLimit(.minutes(1))
)
func restartedSessionIsAttachedAgain() async {
  // `TerminalSession.id` identifies the work session, not the process: a restart hands out a new
  // session object under the same id, and a surface that compared ids would stay attached to the
  // process that is gone — a terminal frozen over a live agent.
  let id = TerminalID()
  let coordinator = makeCoordinator(terminalID: id)
  let first = CountingSession(id: id)
  let restarted = CountingSession(id: id)

  coordinator.attachIfNeeded(to: first)
  #expect(await attachCount(of: first) == 1)

  coordinator.attachIfNeeded(to: restarted)

  #expect(await attachCount(of: restarted) == 1)
}

@MainActor
@Test(
  "Attaching twice to the same session reads its history once",
  .timeLimit(.minutes(1))
)
func repeatedAttachIsIgnored() async {
  let id = TerminalID()
  let coordinator = makeCoordinator(terminalID: id)
  let session = CountingSession(id: id)

  coordinator.attachIfNeeded(to: session)
  #expect(await attachCount(of: session) == 1)

  coordinator.attachIfNeeded(to: session)
  try? await Task.sleep(for: .milliseconds(20))

  #expect(await session.attachCount == 1)
}

@MainActor
@Test(
  "A pane installed under an unchanged view is adopted, and its session attached",
  .timeLimit(.minutes(1))
)
func adoptedPaneIsAttached() async {
  // A relaunch replaces the pane while SwiftUI keeps the same view identity.
  let id = TerminalID()
  let coordinator = makeCoordinator(terminalID: id)
  let session = CountingSession(id: id)
  coordinator.attachIfNeeded(to: session)
  #expect(await attachCount(of: session) == 1)

  coordinator.adopt(pane: makePaneModel(terminalID: id))
  let restarted = CountingSession(id: id)
  coordinator.attachIfNeeded(to: restarted)

  #expect(await attachCount(of: restarted) == 1)
}

@MainActor
@Test("A pane behind the visible one is hidden, so it is not drawn, and shown again when active")
func inactivePaneIsHidden() {
  // Every pane stays mounted: at zero opacity alone, each busy agent behind the visible one kept
  // repainting on the main thread, and typing in the visible terminal lagged behind them.
  let coordinator = makeCoordinator(terminalID: TerminalID())
  let view = TerminalView()

  coordinator.followActivation(false, in: view)
  #expect(view.isHidden)

  coordinator.followActivation(true, in: view)
  #expect(!view.isHidden)
}

@MainActor
@Test("A pane put away gives the keyboard back to no one, not to the next control in the window")
func hiddenPaneDoesNotPassTheKeyboardOn() {
  let coordinator = makeCoordinator(terminalID: TerminalID())
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
    styleMask: [.titled],
    backing: .buffered,
    defer: true
  )
  let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
  let neighbour = NSTextField(frame: NSRect(x: 220, y: 0, width: 160, height: 24))
  window.contentView?.addSubview(view)
  window.contentView?.addSubview(neighbour)
  view.nextKeyView = neighbour

  coordinator.followActivation(true, in: view)
  #expect(window.firstResponder === view)

  coordinator.followActivation(false, in: view)

  #expect(view.isHidden)
  #expect(window.firstResponder === window)
}

/// Waits for the pane to have been written to, however long a busy runner takes.
@MainActor
private func received(_ pane: TerminalPaneModel) async {
  while !pane.hasReceivedInput { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
@Test(
  "What the terminal answers the program is not the user typing; a key is (#411)",
  .timeLimit(.minutes(1))
)
func terminalRepliesAreNotKeystrokes() async {
  let pane = makePaneModel(terminalID: TerminalID())
  let coordinator = TerminalSurfaceCoordinator(pane: pane)
  let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
  view.terminalDelegate = coordinator
  // What Claude Code sends once a command is typed at its prompt: the terminal answers.
  view.getTerminal().feed(text: "\u{1B}[?1004h\u{1B}[>0q\u{1B}[c")
  view.getTerminal().setTerminalFocus(false)
  await received(pane)
  try? await Task.sleep(for: .milliseconds(50))
  #expect(pane.lastKeyboardInputAt == nil)

  coordinator.send(source: view, data: Array("a".utf8)[...])
  while pane.lastKeyboardInputAt == nil { try? await Task.sleep(for: .milliseconds(5)) }
}

@Test(
  "Answers and focus reports are told from keys",
  arguments: [
    ("\u{1B}[I", true), ("\u{1B}[O\u{1B}[I", true), ("\u{1B}[?62;22c", true),
    ("\u{1B}[>0;276;0c", true), ("\u{1B}P>|SwiftTerm(1.2)\u{1B}\\", true),
    ("\u{1B}]11;rgb:0000/0000/0000\u{07}", true), ("\u{1B}[?1004;1$y", true), ("\u{1B}[?0u", true),
    ("\u{1B}[A", false), ("\u{1B}", false), ("a", false), ("\u{1B}[Ia", false), ("", false),
    ("\u{1B}[1;2R", false), ("\u{1B}P>|unfinished", false),
  ])
func terminalReplies(_ text: String, _ isReply: Bool) {
  #expect(TerminalReply.isReply(Array(text.utf8)) == isReply)
}
