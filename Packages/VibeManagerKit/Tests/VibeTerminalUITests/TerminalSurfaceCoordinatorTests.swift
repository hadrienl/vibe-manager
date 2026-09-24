import AppKit
import Foundation
import SwiftTerm
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminalUI

/// A session that records how many views asked it for its history and its stream.
private actor CountingSession: TerminalSession {
  nonisolated let id: SessionID
  private(set) var attachCount = 0

  init(id: SessionID) {
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
  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    CountingSession(id: id)
  }

  func session(for id: SessionID) -> (any TerminalSession)? { nil }
  func stop(id: SessionID, gracePeriod: Duration) {}
  func stopAll(gracePeriod: Duration) {}
}

@MainActor
private func makeCoordinator(sessionID: SessionID) -> TerminalSurfaceCoordinator {
  TerminalSurfaceCoordinator(pane: makePaneModel(sessionID: sessionID))
}

@MainActor
private func makePaneModel(sessionID: SessionID) -> TerminalPaneModel {
  TerminalPaneModel(
    sessionID: sessionID,
    supervisor: IdleSupervisor(),
    spec: TerminalSpec(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ),
    viewportTimeout: .zero
  )
}

private func attachCount(of session: CountingSession) async -> Int {
  for _ in 0..<200 {
    let count = await session.attachCount
    if count > 0 { return count }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await session.attachCount
}

@MainActor
@Test("A restarted session is attached again, although it carries the same session id")
func restartedSessionIsAttachedAgain() async {
  // `TerminalSession.id` identifies the work session, not the process: a restart hands out a new
  // session object under the same id, and a surface that compared ids would stay attached to the
  // process that is gone — a terminal frozen over a live agent.
  let id = SessionID()
  let coordinator = makeCoordinator(sessionID: id)
  let first = CountingSession(id: id)
  let restarted = CountingSession(id: id)

  coordinator.attachIfNeeded(to: first)
  #expect(await attachCount(of: first) == 1)

  coordinator.attachIfNeeded(to: restarted)

  #expect(await attachCount(of: restarted) == 1)
}

@MainActor
@Test("Attaching twice to the same session reads its history once")
func repeatedAttachIsIgnored() async {
  let id = SessionID()
  let coordinator = makeCoordinator(sessionID: id)
  let session = CountingSession(id: id)

  coordinator.attachIfNeeded(to: session)
  #expect(await attachCount(of: session) == 1)

  coordinator.attachIfNeeded(to: session)
  try? await Task.sleep(for: .milliseconds(20))

  #expect(await session.attachCount == 1)
}

@MainActor
@Test("A pane installed under an unchanged view is adopted, and its session attached")
func adoptedPaneIsAttached() async {
  // A relaunch replaces the pane while SwiftUI keeps the same view identity.
  let id = SessionID()
  let coordinator = makeCoordinator(sessionID: id)
  let session = CountingSession(id: id)
  coordinator.attachIfNeeded(to: session)
  #expect(await attachCount(of: session) == 1)

  coordinator.adopt(pane: makePaneModel(sessionID: id))
  let restarted = CountingSession(id: id)
  coordinator.attachIfNeeded(to: restarted)

  #expect(await attachCount(of: restarted) == 1)
}

@MainActor
@Test("A pane behind the visible one is hidden, so it is not drawn, and shown again when active")
func inactivePaneIsHidden() {
  // Every pane stays mounted: at zero opacity alone, each busy agent behind the visible one kept
  // repainting on the main thread, and typing in the visible terminal lagged behind them.
  let coordinator = makeCoordinator(sessionID: SessionID())
  let view = TerminalView()

  coordinator.followActivation(false, in: view)
  #expect(view.isHidden)

  coordinator.followActivation(true, in: view)
  #expect(!view.isHidden)
}

@MainActor
@Test("A pane put away gives the keyboard back to no one, not to the next control in the window")
func hiddenPaneDoesNotPassTheKeyboardOn() {
  let coordinator = makeCoordinator(sessionID: SessionID())
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
