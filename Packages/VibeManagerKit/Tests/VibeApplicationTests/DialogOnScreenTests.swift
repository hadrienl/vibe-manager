import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private let t1 = Date(timeIntervalSince1970: 4_000_000)

/// Reports permissions as Codex does — before their dialog is drawn — and says, on its terminal,
/// which dialog it draws: `start:` quotes the start of a command, `whole:` all of it, `file:` a
/// file a patch writes to. A patch writes to the files of its payload, in `/p`.
private struct CodexLikeDecoder: AgentSignalDecoding {
  let approvalAnswerKeys: Set<[UInt8]> = [[0x79], [0x0D]]

  var answerKeymap: (any AgentAnswerKeymap)? {
    ScreenKeymap()
  }

  var readsTerminalNotifications: Bool {
    true
  }

  func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "start": return .channelConfirmed
    case "ask":
      let command = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
      return .questionAsked(
        .approval, tool: "Bash",
        notice: AgentRequestNotice(
          content: .permission(
            AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
          reference: AgentToolReference(tool: "Bash", subject: command), isShown: false))
    case "patch":
      let files = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
      return .questionAsked(
        .approval, tool: "apply_patch",
        notice: AgentRequestNotice(
          content: .permission(
            AgentToolPermission(
              tool: .patch, toolName: "apply_patch", subject: files, workingDirectory: "/p")),
          reference: AgentToolReference(tool: "apply_patch", subject: files), isShown: false))
    case "mcp":
      return .questionAsked(
        .approval, tool: "mcp__echo_box__write_note",
        notice: AgentRequestNotice(
          content: .permission(
            AgentToolPermission(
              tool: .mcp(server: "echo_box", tool: "write_note"),
              toolName: "mcp__echo_box__write_note", subject: nil)),
          reference: AgentToolReference(tool: "mcp__echo_box__write_note"), isShown: false))
    // A tool ran, which one is not said: Codex's `PostToolUse`.
    case "done": return .questionResolved
    default: return nil
    }
  }

  func signal(forTerminalNotification message: String) -> AgentSignal? {
    if message.hasPrefix("start:") {
      return .dialogDrawn(AgentDrawnDialog(.commandStart(String(message.dropFirst(6)))))
    }
    if message.hasPrefix("whole:") {
      return .dialogDrawn(AgentDrawnDialog(.command(String(message.dropFirst(6)))))
    }
    if message.hasPrefix("server:") {
      return .dialogDrawn(AgentDrawnDialog(.server(String(message.dropFirst(7)))))
    }
    if message.hasPrefix("file:") {
      return .dialogDrawn(AgentDrawnDialog(.file(String(message.dropFirst(5)))))
    }
    return nil
  }
}

/// Reads the command a dialog shows from its `$ ` line, a patch's paths from its `Destination: `
/// lines, and allows with `y`.
private struct ScreenKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.allowOnce, .deny]
  }

  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    answer == .allowOnce ? [[0x79]] : [[0x1B]]
  }

  var readsRequestOnScreen: Bool {
    true
  }

  func drawnDialog(onScreen text: String) -> AgentDrawnDialog? {
    let lines = text.split(separator: "\n")
    if let line = lines.last(where: { $0.hasPrefix("$ ") }) {
      return AgentDrawnDialog(.shownCommand(String(line.dropFirst(2))))
    }
    let paths = lines.filter { $0.hasPrefix("Destination: ") }.map {
      String($0.dropFirst("Destination: ".count))
    }
    return paths.isEmpty ? nil : AgentDrawnDialog(.patch(Set(paths)))
  }
}

/// The screen a terminal shows, which a test changes.
private actor Screen {
  var text: String?

  func show(_ text: String?) {
    self.text = text
  }
}

private actor Written {
  var bytes: [[UInt8]] = []

  func append(_ step: [UInt8]) {
    bytes.append(step)
  }
}

private struct Fixture {
  let logs = ScriptedActivityLogs()
  let tracker: TrackAgentActivity
  let screen = Screen()
  let written = Written()
  let answer: AnswerAgentRequest
  let id = SessionID()

  init(sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
    try await Task.sleep(for: .seconds(3600))
  }) {
    tracker = TrackAgentActivity(
      logs: logs, store: MemoryActivityStore(), now: { t1 }, sleep: sleep,
      persistenceDelay: .seconds(3600))
    let screen = screen
    let written = written
    answer = AnswerAgentRequest(
      tracker: tracker,
      write: { _, bytes in
        await written.append(bytes)
        return true
      },
      screen: { _ in await screen.text },
      sleep: { _ in })
  }

  func start() async {
    await tracker.processStarted(id, decoder: CodexLikeDecoder())
    #expect(await following(logs, id))
    await logs.write("start", at: t1, for: id)
    #expect(await eventually(tracker, id) { $0?.source == .structured })
  }

  /// The agent asks to run `command` — or to write to `files`, one per line — its report read at
  /// once.
  func ask(_ command: String, event: String = "ask") async -> AgentRequestID {
    let count = await tracker.state(for: id)?.requests.count ?? 0
    await logs.write(event, at: t1, for: id, payload: command)
    #expect(await eventually(tracker, id) { $0?.requests.count == count + 1 })
    return await tracker.state(for: id)?.requests.last?.id
      ?? AgentRequestID(sessionID: id, key: "none")
  }

  /// Returns once the end of the log has been asked for: the answer is waiting for it.
  func endAsked() async {
    while await logs.endsAsked[id] == nil, !Task.isCancelled { await Task.yield() }
  }

  func answering(_ request: AgentRequestID) async -> AgentRequestAnswering? {
    await tracker.answering(for: id)[request]
  }
}

@Suite("Which request a dialog is, read off the screen (#283)", .timeLimit(.minutes(2)))
struct DialogOnScreenTests {
  // MARK: - What a dialog shows

  @Test("A wrapped command is the command, however the terminal broke its lines")
  func wrappedCommand() {
    let dialog = AgentDrawnDialog(.shownCommand("printf a-b-c-\nd > /dev/null"))
    let request = permission(.shell, "printf a-b-c-d > /dev/null")
    #expect(dialog.matches(request))
    #expect(!dialog.matches(permission(.shell, "printf a-b-c-d > /dev/nul")))
    #expect(dialog.quotesWhole)
  }

  @Test("A patch is every path it writes to, its relative ones against its working directory")
  func patch() {
    let dialog = AgentDrawnDialog(.patch(["/proj/notes.txt", "/proj/App/Mo\ndel.swift"]))
    #expect(dialog.matches(permission(.patch, "notes.txt\nApp/Model.swift", in: "/proj")))
    #expect(dialog.matches(permission(.patch, "/proj/notes.txt\n./App/Model.swift", in: "/proj")))
    // One file more, or less, is another patch.
    #expect(!dialog.matches(permission(.patch, "notes.txt", in: "/proj")))
    #expect(!dialog.matches(permission(.patch, "notes.txt\nApp/Model.swift\nb", in: "/proj")))
    #expect(!dialog.matches(permission(.patch, "notes.txt\nApp/Model.swift", in: "/other")))
  }

  @Test("Within a line, a command is read blank for blank")
  func blanksWithinALine() {
    let dialog = AgentDrawnDialog(.shownCommand("rm -rf / tmp/x"))
    #expect(!dialog.matches(permission(.shell, "rm -rf /tmp/x")))
    #expect(dialog.matches(permission(.shell, "rm -rf / tmp/x")))
    // A command's own lines, their indent taken off by the dialog.
    let heredoc = AgentDrawnDialog(.shownCommand("cat <<EOF\nindented\nEOF"))
    #expect(heredoc.matches(permission(.shell, "cat <<EOF\n    indented\nEOF")))
  }

  @Test("A host is the target of a network access, whose dialog shows no command")
  func host() {
    let host = AgentDrawnDialog(.host("example.org"))
    let access = AgentRequest(
      id: AgentRequestID(sessionID: SessionID(), key: "n"), receivedAt: t1, kind: .approval,
      content: .permission(
        AgentToolPermission(
          tool: .shell, toolName: "Bash", subject: "curl x",
          purpose: "network-access https://example.org:443")),
      reference: AgentToolReference(tool: "Bash"), isShown: false)
    #expect(host.matches(access))
    #expect(!AgentDrawnDialog(.host("example.com")).matches(access))
    #expect(!host.matches(permission(.shell, "curl x")))
    // The command's dialog is not the access's, though its command is the same.
    #expect(!AgentDrawnDialog(.shownCommand("curl x")).matches(access))
    #expect(AgentDrawnDialog.host(of: "[::1]:8080") == "::1")
    #expect(!AgentDrawnDialog(.host("::1")).matches(access))
  }

  // MARK: - Answering

  @Test("Two commands that start alike: the first is offered, and answered once the screen shows it")
  func sameStartAnsweredOnScreen() async {
    let fixture = Fixture()
    await fixture.start()
    let first = await fixture.ask("touch alpha")
    _ = await fixture.ask("touch alpine")
    await fixture.tracker.terminalNotification(fixture.id, "start:touch alp")
    #expect(await fixture.answering(first) == .fromPalette([.allowOnce, .deny]))

    await fixture.screen.show("Would you like to run the following command?\n$ touch alpha")
    #expect(await fixture.answer(.allowOnce, to: first) == .sent)
    #expect(await fixture.written.bytes == [[0x79]])
  }

  @Test("The screen shows the other command: nothing is typed, and that one's card takes over")
  func sameStartOtherOnScreen() async {
    let fixture = Fixture()
    await fixture.start()
    let first = await fixture.ask("touch alpha")
    let second = await fixture.ask("touch alpine")
    await fixture.tracker.terminalNotification(fixture.id, "start:touch alp")

    await fixture.screen.show("$ touch alpine")
    #expect(await fixture.answer(.allowOnce, to: first) == .requestGone)
    #expect(await fixture.written.bytes.isEmpty)
    // Drawn after the first and never drawn itself, the first was settled by Codex's review.
    #expect(await fixture.tracker.state(for: fixture.id)?.requests.map(\.id) == [second])
    #expect(await fixture.answering(second) == .fromPalette([.allowOnce, .deny]))
    #expect(await fixture.answer(.allowOnce, to: second) == .sent)
    #expect(await fixture.written.bytes == [[0x79]])
  }

  @Test("A screen that shows no dialog, or one cut short, gets nothing typed", arguments: [
    nil, "› Ask Codex to do anything", "[… 9 lines] ctrl+a view all",
  ])
  func unreadable(_ text: String?) async {
    let fixture = Fixture()
    await fixture.start()
    let first = await fixture.ask("touch alpha")
    _ = await fixture.ask("touch alpine")
    await fixture.tracker.terminalNotification(fixture.id, "start:touch alp")

    await fixture.screen.show(text)
    #expect(await fixture.answer(.allowOnce, to: first) == .otherDialog)
    #expect(await fixture.answer(.deny, to: first) == .otherDialog)
    #expect(await fixture.written.bytes.isEmpty)
  }

  @Test("A request the dialog drawn cannot be stays answered in the session")
  func notACandidate() async {
    let fixture = Fixture()
    await fixture.start()
    let first = await fixture.ask("ls")
    _ = await fixture.ask("touch alpha")
    _ = await fixture.ask("touch alpine")
    await fixture.tracker.terminalNotification(fixture.id, "start:touch alp")
    #expect(await fixture.answering(first) == .inTerminalOnly(.uncertain))
  }

  @Test("The same command twice, the second's report read after its dialog: nothing is typed")
  func sameCommandReportedLate() async {
    let fixture = Fixture()
    await fixture.start()
    // A is settled by Codex's review, with no dialog; B, the very same command, is drawn. Its
    // report was written before its dialog, but is not read yet when the notification is.
    let first = await fixture.ask("rm -rf build")
    await fixture.logs.writeUnread("ask", at: t1, for: fixture.id, payload: "rm -rf build")
    await fixture.tracker.terminalNotification(fixture.id, "whole:rm -rf build")
    #expect(await fixture.answering(first) == .fromPalette([.allowOnce, .deny]))

    await fixture.screen.show("$ rm -rf build")
    let answer = Task { await fixture.answer(.allowOnce, to: first) }
    await fixture.endAsked()
    await fixture.logs.read(fixture.id)
    #expect(await answer.value == .otherDialog)
    #expect(await fixture.written.bytes.isEmpty)
  }

  @Test("Catching up waits until the log is read to its end, not for a while")
  func catchUpWaitsForTheLine() async {
    let fixture = Fixture()
    await fixture.start()
    _ = await fixture.ask("ls")
    await fixture.logs.writeUnread("ask", at: t1, for: fixture.id, payload: "touch a")
    let tracker = fixture.tracker
    let id = fixture.id
    let caughtUp = Task {
      let reached = await tracker.catchUp(id)
      return (reached, await tracker.state(for: id)?.requests.count)
    }
    // The line is read only once the end of the log is known: had the wait not waited, the
    // request would not be there yet.
    await fixture.endAsked()
    await fixture.logs.read(fixture.id)
    let (reached, count) = await caughtUp.value
    #expect(reached)
    #expect(count == 2)
  }

  @Test("A log that is not read in time gets nothing typed")
  func catchUpLimit() async {
    let fixture = Fixture(sleep: { duration in
      // Only the wait for the log ends; nothing else the tracker times does.
      guard duration != TrackAgentActivity.catchUpLimit else { return }
      try await Task.sleep(for: .seconds(3600))
    })
    await fixture.start()
    let first = await fixture.ask("touch alpha")
    await fixture.tracker.terminalNotification(fixture.id, "whole:touch alpha")
    await fixture.logs.writeUnread("ask", at: t1, for: fixture.id, payload: "touch b")

    await fixture.screen.show("$ touch alpha")
    #expect(await fixture.answer(.allowOnce, to: first) == .otherDialog)
    #expect(await fixture.written.bytes.isEmpty)
  }

  @Test("A command quoted whole and alone on screen is answered as before")
  func wholeAndAlone() async {
    let fixture = Fixture()
    await fixture.start()
    let first = await fixture.ask("touch alpha")
    await fixture.tracker.terminalNotification(fixture.id, "whole:touch alpha")
    await fixture.screen.show("$ touch alpha")
    #expect(await fixture.answer(.allowOnce, to: first) == .sent)
  }

  @Test("An MCP tool's form is never read: its request stays answered in the session")
  func mcpTool() async {
    let fixture = Fixture()
    await fixture.start()
    let tool = await fixture.ask("", event: "mcp")
    await fixture.tracker.terminalNotification(fixture.id, "server:echo-box")
    #expect(await fixture.answering(tool) == .inTerminalOnly(.uncertain))
  }

  @Test("A dialog that changed while the log was read gets nothing typed")
  func changedWhileCatchingUp() async {
    let fixture = Fixture()
    await fixture.start()
    let first = await fixture.ask("touch alpha")
    await fixture.tracker.terminalNotification(fixture.id, "whole:touch alpha")
    await fixture.screen.show("$ touch alpha")
    await fixture.logs.writeUnread("ask", at: t1, for: fixture.id, payload: "touch beta")
    let answer = Task { await fixture.answer(.allowOnce, to: first) }
    await fixture.endAsked()
    // Another dialog is drawn meanwhile, its report written after the end the answer waits for.
    await fixture.screen.show("$ touch gamma")
    await fixture.logs.read(fixture.id)
    #expect(await answer.value == .otherDialog)
    #expect(await fixture.written.bytes.isEmpty)
  }

  @Test("Two patches of the same files, not drawn yet, are two requests")
  func samePatchTwice() async {
    let fixture = Fixture()
    await fixture.start()
    _ = await fixture.ask("a.txt", event: "patch")
    _ = await fixture.ask("a.txt", event: "patch")
    #expect(await fixture.tracker.state(for: fixture.id)?.requests.count == 2)
  }

  @Test("A request taken away on a guess: a patch drawn may be its, a command reads the same")
  func trackLost() async {
    let fixture = Fixture()
    await fixture.start()
    _ = await fixture.ask("a.txt", event: "patch")
    let patch = await fixture.ask("a.txt", event: "patch")
    await fixture.tracker.terminalNotification(fixture.id, "file:a.txt")
    // A tool ran: the first is taken as the one, which it may not have been.
    await fixture.logs.write("done", at: t1, for: fixture.id)
    #expect(await eventually(fixture.tracker, fixture.id) { $0?.requests.map(\.id) == [patch] })
    #expect(await fixture.answering(patch) == .fromPalette([.allowOnce, .deny]))
    // The patch on screen may be the one taken away, whose changes are not this one's.
    await fixture.screen.show("Destination: /p/a.txt")
    #expect(await fixture.answer(.allowOnce, to: patch) == .otherDialog)
    #expect(await fixture.written.bytes.isEmpty)

    let other = Fixture()
    await other.start()
    _ = await other.ask("touch a")
    let command = await other.ask("touch a")
    await other.tracker.terminalNotification(other.id, "whole:touch a")
    await other.logs.write("done", at: t1, for: other.id)
    #expect(await eventually(other.tracker, other.id) { $0?.requests.map(\.id) == [command] })
    await other.screen.show("$ touch a")
    #expect(await other.answer(.allowOnce, to: command) == .sent)
  }

  // MARK: -

  private func permission(
    _ tool: AgentToolPermission.Tool, _ subject: String?, in directory: String? = nil
  ) -> AgentRequest {
    AgentRequest(
      id: AgentRequestID(sessionID: SessionID(), key: "r"), receivedAt: t1, kind: .approval,
      content: .permission(
        AgentToolPermission(
          tool: tool, toolName: "t", subject: subject, workingDirectory: directory)),
      reference: AgentToolReference(tool: "t"), isShown: false)
  }
}
