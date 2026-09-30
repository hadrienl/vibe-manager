import AppKit
import Foundation
import SwiftTerm
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminalUI

/// A process that writes what the test says, keeps it all in its history, and records what the
/// terminal answers.
private actor ScriptedSession: TerminalSession {
  nonisolated let id: TerminalID
  private var printed: [UInt8] = []
  private var subscribers: [UUID: AsyncStream<TerminalEvent>.Continuation] = [:]
  /// The pane's watch of the state, which reads no bytes and is told nothing here.
  private var stateReaders: [AsyncStream<TerminalEvent>.Continuation] = []
  /// Everything the view sent back, write by write.
  private(set) var written: [[UInt8]] = []

  init(id: TerminalID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    let subscriberID = UUID()
    subscribers[subscriberID] = continuation
    continuation.onTermination = { _ in Task { await self.remove(subscriberID) } }
    return TerminalAttachment(
      state: .running(processIdentifier: 7),
      history: TerminalHistorySnapshot(bytes: printed, droppedByteCount: 0, startOffset: 0),
      events: events)
  }

  func attach(_ interest: TerminalEventInterest) -> TerminalAttachment {
    guard interest == .state else { return attach() }
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    stateReaders.append(continuation)
    return TerminalAttachment(
      state: .running(processIdentifier: 7),
      history: TerminalHistorySnapshot(bytes: printed, droppedByteCount: 0, startOffset: 0),
      events: events)
  }

  private func remove(_ subscriberID: UUID) {
    subscribers[subscriberID] = nil
  }

  /// How many readers of the bytes are attached.
  var readerCount: Int { subscribers.count }

  func print(_ text: String) {
    let bytes = [UInt8](text.utf8)
    printed += bytes
    for continuation in subscribers.values {
      continuation.yield(.output(bytes))
    }
  }

  /// The answers the terminal sent that report the cursor's position.
  var cursorReports: Int {
    written.map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasSuffix("R") }.count
  }

  func state() -> TerminalProcessState { .running(processIdentifier: 7) }
  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: printed, droppedByteCount: 0)
  }
  func write(_ bytes: [UInt8]) { written.append(bytes) }
  func resize(to size: TerminalSize) {}
  func stop(gracePeriod: Duration) {}
  func kill() {}
}

private actor NoSupervisor: TerminalSupervisor {
  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    throw TerminalError.spawnFailed(code: 1)
  }
  func session(for id: TerminalID) -> (any TerminalSession)? { nil }
  func stop(id: TerminalID, gracePeriod: Duration) {}
  func stopAll(gracePeriod: Duration) {}
}

@MainActor
private struct Harness {
  let session: ScriptedSession
  let pane: TerminalPaneModel
  let coordinator: TerminalSurfaceCoordinator
  let view: TerminalView

  static func make() async -> Harness {
    let id = TerminalID()
    let session = ScriptedSession(id: id)
    let pane = TerminalPaneModel(
      terminalID: id, supervisor: NoSupervisor(), spec: nil, viewportTimeout: .zero)
    // The pane sends the view's answers to the process, as it does to a real one.
    await pane.adopt(session)
    let coordinator = TerminalSurfaceCoordinator(pane: pane, suspensionDelay: .zero)
    // Never put in a window, never shown.
    let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    view.terminalDelegate = coordinator
    coordinator.bind(to: view)
    coordinator.attachIfNeeded(to: session)
    return Harness(session: session, pane: pane, coordinator: coordinator, view: view)
  }

  var screen: String {
    let terminal = view.getTerminal()
    return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString() }
      .joined(separator: "\n")
  }

  func waitForScreen(containing text: String) async {
    while !screen.contains(text) { try? await Task.sleep(for: .milliseconds(5)) }
  }

  func putAway() async {
    coordinator.followActivation(false, in: view)
    while !coordinator.isSuspended { try? await Task.sleep(for: .milliseconds(5)) }
    // Only the sentinel reads the bytes now.
    while await session.readerCount != 1 { try? await Task.sleep(for: .milliseconds(5)) }
  }
}

@MainActor
@Suite("A terminal put away is not fed, and catches up when shown (#248)", .timeLimit(.minutes(1)))
struct TerminalSuspensionTests {
  @Test("Hidden, written to, then shown: the screen is the one a view fed all along would show")
  func catchesUpToTheSameScreen() async {
    let harness = await Harness.make()
    await harness.session.print("first line\r\n")
    await harness.waitForScreen(containing: "first line")

    await harness.putAway()
    var written = "first line\r\n"
    // Well past one slice of catch-up.
    for index in 0..<4_000 {
      let line = "\u{1B}[3\(index % 8)mline \(index)\u{1B}[0m\r\n"
      written += line
      await harness.session.print(line)
    }
    await harness.session.print("\u{1B}[2;5Hover")
    written += "\u{1B}[2;5Hover"
    #expect(!harness.screen.contains("line 3999"))

    harness.coordinator.followActivation(true, in: harness.view)
    await harness.waitForScreen(containing: "line 3999")
    while !harness.screen.contains("over") { try? await Task.sleep(for: .milliseconds(5)) }

    let reference = TerminalView(frame: harness.view.frame)
    reference.feed(byteArray: Array(written.utf8)[...])
    let referenceScreen = (0..<reference.getTerminal().rows)
      .compactMap { reference.getTerminal().getLine(row: $0)?.translateToString() }
      .joined(separator: "\n")
    #expect(harness.screen == referenceScreen)
    let cursor = harness.view.getTerminal().getCursorLocation()
    let referenceCursor = reference.getTerminal().getCursorLocation()
    #expect(cursor.x == referenceCursor.x)
    #expect(cursor.y == referenceCursor.y)
    #expect(!harness.coordinator.isSuspended)
    #expect(written.utf8.count > TerminalSurfaceCoordinator.catchUpSliceSize)
    // Drawn again, and the pane no longer says it is catching up.
    #expect(harness.view.alphaValue == 1)
    #expect(!harness.pane.isCatchingUp)
  }

  @Test("A question asked of a suspended terminal is answered without showing it")
  func sentinelAnswersWhileSuspended() async {
    let harness = await Harness.make()
    await harness.putAway()

    await harness.session.print("prompt> \u{1B}[6n")
    while await harness.session.cursorReports < 1 { try? await Task.sleep(for: .milliseconds(5)) }

    let answer = String(decoding: await harness.session.written.last ?? [], as: UTF8.self)
    // Row 1, column 9: after the eight characters of the prompt.
    #expect(answer == "\u{1B}[1;9R")
    #expect(harness.coordinator.sentinelWakeCount >= 1)
    #expect(harness.coordinator.isSuspended)
    #expect(harness.view.isHidden)
  }

  @Test("A question the view already answered is not answered again when it catches up")
  func caughtUpBytesAreNotAnsweredTwice() async {
    let harness = await Harness.make()
    await harness.session.print("\u{1B}[6n")
    while await harness.session.cursorReports < 1 { try? await Task.sleep(for: .milliseconds(5)) }

    await harness.putAway()
    await harness.session.print("quiet output\r\n")
    harness.coordinator.followActivation(true, in: harness.view)
    await harness.waitForScreen(containing: "quiet output")
    // A new question after the catch-up is answered once.
    await harness.session.print("\u{1B}[6n")
    while await harness.session.cursorReports < 2 { try? await Task.sleep(for: .milliseconds(5)) }

    #expect(await harness.session.cursorReports == 2)
  }

  @Test("A view shown again before its delay is never suspended")
  func quickLookAwayKeepsFeeding() async {
    let id = TerminalID()
    let session = ScriptedSession(id: id)
    let pane = TerminalPaneModel(
      terminalID: id, supervisor: NoSupervisor(), spec: nil, viewportTimeout: .zero)
    let coordinator = TerminalSurfaceCoordinator(pane: pane, suspensionDelay: .seconds(3_600))
    let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    coordinator.bind(to: view)
    coordinator.attachIfNeeded(to: session)

    coordinator.followActivation(false, in: view)
    await session.print("still fed\r\n")
    while !(0..<view.getTerminal().rows).contains(where: {
      view.getTerminal().getLine(row: $0)?.translateToString().contains("still fed") ?? false
    }) {
      try? await Task.sleep(for: .milliseconds(5))
    }
    coordinator.followActivation(true, in: view)

    #expect(!coordinator.isSuspended)
  }
}
