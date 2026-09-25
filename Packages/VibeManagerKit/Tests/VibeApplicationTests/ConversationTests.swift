import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

// MARK: - Diffs

@Suite("Unified diffs, cut in hunks")
struct UnifiedDiffParserTests {
  @Test("Hunks keep both line numbers, and skip the file headers")
  func hunks() {
    let diff = """
      --- a/Sources/Tail.swift
      +++ b/Sources/Tail.swift
      @@ -10,3 +10,4 @@ struct Tail {
       let file: URL
      -var offset = 0
      +var offset: UInt64 = 0
      +var inode: UInt64?
       init() {}
      \\ No newline at end of file
      @@ -40 +41 @@
      -a
      +b
      """
    let (hunks, omitted) = UnifiedDiffParser.hunks(in: diff)
    #expect(omitted == 0)
    #expect(hunks.count == 2)
    #expect(hunks[0].oldStart == 10)
    #expect(hunks[0].lines.map(\.kind) == [.context, .removed, .added, .added, .context])
    #expect(hunks[0].lines[1].oldNumber == 11)
    #expect(hunks[0].lines[1].newNumber == nil)
    #expect(hunks[0].lines[3].newNumber == 12)
    #expect(hunks[0].lines[4].oldNumber == 12)
    #expect(hunks[0].lines[4].newNumber == 13)
    #expect(hunks[1].oldStart == 40 && hunks[1].newStart == 41)
  }

  @Test("Past the limit, lines are counted rather than kept")
  func limit() {
    let diff = "@@ -1,5 +1,5 @@\n" + (1...5).map { "+line \($0)" }.joined(separator: "\n")
    let (hunks, omitted) = UnifiedDiffParser.hunks(in: diff, limit: 3)
    #expect(hunks[0].lines.count == 3)
    #expect(omitted == 2)
  }

  @Test("A new file is one hunk of added lines")
  func addition() {
    let (hunks, _) = UnifiedDiffParser.addition(of: "a\nb\n")
    #expect(hunks[0].lines.map(\.text) == ["a", "b"])
    #expect(hunks[0].lines.map(\.newNumber) == [1, 2])
    let change = FileDiff(path: "/x/y.swift", kind: .added, hunks: hunks)
    #expect(change.addedLineCount == 2)
    #expect(change.fileName == "y.swift")
  }
}

// MARK: - Test runs

@Suite("Recognising how a test run ended")
struct TestOutcomeRecognizerTests {
  @Test(
    "Each runner's summary line",
    arguments: [
      ("✔ Test run with 42 tests in 5 suites passed after 1.2 seconds.", 42, 0),
      ("✘ Test run with 9 tests in 2 suites failed after 0.004 seconds with 1 issue.", 9, 1),
      ("Executed 42 tests, with 3 failures (0 unexpected) in 1.234 (1.240) seconds", 42, 3),
      ("===== 3 failed, 39 passed in 1.23s =====", 42, 3),
      ("======== 12 passed in 0.50s ========", 12, 0),
      ("Tests:       3 failed, 39 passed, 42 total", 42, 3),
      ("Tests:       7 passed, 7 total", 7, 0),
      ("      Tests  2 failed | 10 passed (12)", 12, 2),
      (
        "test result: ok. 4 passed; 0 failed; 0 ignored\ntest result: FAILED. 1 passed; 2 failed; 0 ignored",
        7, 2
      ),
      ("--- PASS: TestA (0.00s)\n--- FAIL: TestB (0.00s)\n--- PASS: TestC (0.00s)", 3, 1),
    ])
  func summary(output: String, total: Int, failed: Int) {
    #expect(TestOutcomeRecognizer.outcome(in: output) == TestOutcome(total: total, failed: failed))
  }

  @Test("Only a command that runs tests is read for them")
  func onlyTestCommands() {
    let summary = "Executed 9 tests, with 1 failure (0 unexpected) in 1.0 (1.0) seconds"
    #expect(TestOutcomeRecognizer.outcome(of: "swift test --filter Tail", output: summary) != nil)
    #expect(TestOutcomeRecognizer.outcome(of: "cd pkg && npm run test", output: summary) != nil)
    #expect(
      TestOutcomeRecognizer.outcome(of: "xcodebuild -scheme App test", output: summary) != nil)
    #expect(TestOutcomeRecognizer.outcome(of: "cat /tmp/ci.log", output: summary) == nil)
    #expect(TestOutcomeRecognizer.outcome(of: "grep -r latest src", output: summary) == nil)
  }

  @Test("Anything else is not a test run")
  func unknown() {
    #expect(TestOutcomeRecognizer.outcome(in: "Build complete!") == nil)
    #expect(TestOutcomeRecognizer.outcome(in: "") == nil)
  }
}

// MARK: - Grouping

@Suite("Folding consecutive tool calls")
struct ConversationGroupingTests {
  private func call(_ id: String, _ kind: ToolKind, _ state: ToolCallState = .succeeded)
    -> ConversationEntry
  {
    ConversationEntry(id: id, content: .tool(ToolCall(callID: id, kind: kind, state: state)))
  }

  private func text(_ id: String) -> ConversationEntry {
    ConversationEntry(id: id, content: .agentText("…"))
  }

  @Test("Calls of the same family fold together, named after the first")
  func sameFamily() {
    let blocks = ConversationGrouping.blocks([
      call("a", .read), call("b", .read), call("c", .read), call("d", .shell),
    ])
    #expect(blocks.map(\.id) == ["group:a", "d"])
    guard case .toolGroup(_, let calls) = blocks[0] else {
      Issue.record("not a group")
      return
    }
    #expect(calls.count == 3)
  }

  @Test("A search and a listing are one family; an edit and a read are not")
  func families() {
    let blocks = ConversationGrouping.blocks([
      call("a", .search), call("b", .list), call("c", .edit), call("d", .read),
    ])
    #expect(blocks.map(\.id) == ["group:a", "c", "d"])
  }

  @Test("What the agent says in between breaks a group")
  func textBreaks() {
    let blocks = ConversationGrouping.blocks([call("a", .read), text("t"), call("b", .read)])
    #expect(blocks.map(\.id) == ["a", "t", "b"])
  }

  @Test("Silent reasoning between calls folds in; reasoning with words does not")
  func reasoning() {
    let silent = ConversationEntry(id: "r", content: .reasoning(nil))
    let spoken = ConversationEntry(id: "s", content: .reasoning("thinking"))
    #expect(
      ConversationGrouping.blocks([call("a", .read), silent, call("b", .read)]).map(\.id)
        == ["group:a"])
    #expect(
      ConversationGrouping.blocks([call("a", .read), spoken, call("b", .read)]).map(\.id)
        == ["a", "s", "b"])
    #expect(ConversationGrouping.blocks([call("a", .read), silent]).map(\.id) == ["a", "r"])
  }

  @Test("Reasoning next to reasoning is one row")
  func mergedReasoning() {
    let blocks = ConversationGrouping.blocks([
      ConversationEntry(id: "r1", content: .reasoning(nil)),
      ConversationEntry(id: "r2", content: .reasoning("because")),
      text("t"),
    ])
    #expect(blocks.map(\.id) == ["r1", "t"])
    guard case .entry(let merged) = blocks[0] else { return }
    #expect(merged.content == .reasoning("because"))
  }

  @Test("A call waiting for a permission stands on its own, and a failure shows on its group")
  func states() {
    let blocks = ConversationGrouping.blocks([
      call("a", .shell), call("b", .shell, .failed(exitCode: 1)), call("c", .shell),
      call("d", .shell, .awaitingPermission),
    ])
    #expect(blocks.map(\.id) == ["group:a", "d"])
    #expect(blocks[0].toolState == .failed(exitCode: 1))
  }

  @Test("To-do lists, plans and questions are never folded")
  func ungroupable() {
    let blocks = ConversationGrouping.blocks([call("a", .todo), call("b", .todo)])
    #expect(blocks.map(\.id) == ["a", "b"])
  }

  @Test("Turned off, every call is its own block")
  func off() {
    let blocks = ConversationGrouping.blocks([call("a", .read), call("b", .read)], grouping: false)
    #expect(blocks.map(\.id) == ["a", "b"])
  }

  @Test("Adding entries at the end never changes the blocks above")
  func stability() {
    let first = [text("t"), call("a", .read), call("b", .read)]
    let before = ConversationGrouping.blocks(first)
    let after = ConversationGrouping.blocks(first + [call("c", .read), text("u")])
    #expect(after.map(\.id).prefix(before.count) == before.map(\.id)[...])
  }

  @Test("The last running call is the one a permission holds up")
  func pendingPermission() {
    let entries = [call("a", .shell, .running), call("b", .shell, .running)]
    let marked = ConversationEntry.markingPendingPermission(
      entries, activity: .awaitingUser(.approval))
    #expect(marked.map { $0.toolCall?.state } == [.running, .awaitingPermission])
    #expect(
      ConversationEntry.markingPendingPermission(entries, activity: .working).map {
        $0.toolCall?.state
      } == [.running, .running])
  }
}

// MARK: - Titles

@Suite("The titles of tool calls")
struct ToolCallSummaryTests {
  @Test("A read names the file and its lines")
  func read() {
    let call = ToolCall(
      callID: "1", kind: .read,
      parameters: [
        ToolParameter(.path, "/p/Sources/Session.swift"), ToolParameter(.lines, "10–80"),
      ])
    let title = ToolCallSummary.title(for: call)
    #expect(title.title == "Read Session.swift")
    #expect(title.detail == "lines 10–80")
    #expect(title.symbolName == "doc.text")
  }

  @Test("A command reads as the agent described it, and says how its tests went")
  func shell() {
    var call = ToolCall(
      callID: "1", kind: .shell, state: .succeeded,
      parameters: [ToolParameter(.command, "swift test --filter Tail\necho done")],
      summary: "Run the tail's tests")
    call.facts.tests = TestOutcome(total: 42, failed: 0)
    var title = ToolCallSummary.title(for: call)
    #expect(title.title == "Run the tail's tests")
    #expect(title.detail == "swift test --filter Tail")
    #expect(title.outcome == "42 tests passed")

    call.summary = nil
    call.facts.tests = TestOutcome(total: 9, failed: 1)
    call.state = .failed(exitCode: 1)
    title = ToolCallSummary.title(for: call)
    #expect(title.title == "swift test --filter Tail")
    #expect(title.outcome == "1 of 9 tests failed")

    call.facts.tests = nil
    call.state = .failed(exitCode: 2)
    #expect(ToolCallSummary.title(for: call).outcome == "exit code 2")
  }

  @Test("Edits, searches, the web, MCP and sub-agents")
  func others() {
    #expect(
      ToolCallSummary.title(
        for: ToolCall(callID: "1", kind: .edit, parameters: [ToolParameter(.path, "/a/b.swift")])
      ).title == "Edited b.swift")
    #expect(
      ToolCallSummary.title(
        for: ToolCall(callID: "1", kind: .create, parameters: [ToolParameter(.path, "/a/c.md")])
      ).title == "Created c.md")
    var search = ToolCall(
      callID: "1", kind: .search, parameters: [ToolParameter(.pattern, "TranscriptTail")])
    search.facts.resultCount = 12
    #expect(ToolCallSummary.title(for: search).title == "Searched for TranscriptTail")
    #expect(ToolCallSummary.title(for: search).detail == "12 results")
    #expect(
      ToolCallSummary.title(
        for: ToolCall(
          callID: "1", kind: .webFetch,
          parameters: [ToolParameter(.url, "https://developer.apple.com/documentation")])
      ).title == "Read developer.apple.com")
    #expect(
      ToolCallSummary.title(
        for: ToolCall(callID: "1", kind: .mcp(server: "github", tool: "issues"))
      )
      .title == "github · issues")
    #expect(
      ToolCallSummary.title(
        for: ToolCall(
          callID: "1", kind: .subagent, parameters: [ToolParameter(.description, "Review")])
      ).title == "Sub-agent: Review")
  }

  @Test("A group says what its calls did together, and how many failed")
  func group() {
    let reads = (1...5).map {
      ToolCall(callID: "\($0)", kind: .read, parameters: [ToolParameter(.path, "/a/\($0).swift")])
    }
    let title = ToolCallSummary.title(forGroup: reads)
    #expect(title.title == "5 files read")
    #expect(title.outcome == nil)
    let commands = [
      ToolCall(
        callID: "1", kind: .shell, state: .succeeded, parameters: [ToolParameter(.command, "ls")]),
      ToolCall(
        callID: "2", kind: .shell, state: .failed(exitCode: 1),
        parameters: [ToolParameter(.command, "make")]),
    ]
    let group = ToolCallSummary.title(forGroup: commands)
    #expect(group.title == "2 commands")
    #expect(group.outcome == "1 failed")
    #expect(group.detail == "ls · make")
  }

  @Test("An output too long keeps its beginning and its end")
  func boundedOutput() {
    let text = String(repeating: "a", count: 100) + String(repeating: "z", count: 100)
    let output = ToolOutput.bounded(text, limit: 20)
    #expect(output.text.hasPrefix("aaaaaaaaaa"))
    #expect(output.text.hasSuffix("zzzzzzzzzz"))
    #expect(output.omittedByteCount == 180)
    #expect(ToolOutput.bounded("short").omittedByteCount == 0)
  }
}

// MARK: - Prompts

@Suite("A prompt written into the agent's terminal")
struct PromptEncodingTests {
  @Test("A bracketed paste, then the key that sends it")
  func bracketed() {
    let keys = PromptEncoding.keystrokes(
      for: PromptSubmission(text: "line 1\nline 2"), format: AgentPromptFormat(),
      whileWorking: false)
    #expect(keys.paste == Array("\u{1B}[200~line 1\nline 2\u{1B}[201~".utf8))
    #expect(keys.submit == [0x0D])
  }

  @Test("While the agent works, the provider's queue key sends it")
  func queued() {
    let keys = PromptEncoding.keystrokes(
      for: PromptSubmission(text: "next"), format: AgentPromptFormat(queueKey: [0x09]),
      whileWorking: true)
    #expect(keys.submit == [0x09])
  }

  @Test("No control character reaches the terminal, and the paste cannot be closed from inside")
  func sanitized() {
    let keys = PromptEncoding.keystrokes(
      for: PromptSubmission(text: "a\u{1B}[201~\u{7}b\r\nc\td"), format: AgentPromptFormat(),
      whileWorking: false)
    #expect(keys.paste == Array("\u{1B}[200~a[201~b\nc\td\u{1B}[201~".utf8))
  }

  @Test("A file named with a control character is never written into the terminal")
  func trappedPath() {
    let trap = URL(fileURLWithPath: "/tmp/a\u{1B}[201~\rrm -rf ~\r.png")
    let keys = PromptEncoding.keystrokes(
      for: PromptSubmission(text: "look", attachments: [trap]), format: AgentPromptFormat(),
      whileWorking: false)
    #expect(keys.paste == Array("\u{1B}[200~look\u{1B}[201~".utf8))
    #expect(!PromptEncoding.isWritablePath(trap.path))
  }

  @Test("Joined files follow the text, escaped as Terminal.app drops them")
  func attachments() {
    let keys = PromptEncoding.keystrokes(
      for: PromptSubmission(
        text: "look", attachments: [URL(fileURLWithPath: "/Users/a/My Shot (1).png")]),
      format: AgentPromptFormat(usesBracketedPaste: false), whileWorking: false)
    #expect(String(decoding: keys.paste, as: UTF8.self) == #"look /Users/a/My\ Shot\ \(1\).png"#)
    #expect(PromptSubmission(text: "  \n").isEmpty)
    #expect(!PromptSubmission(text: "", attachments: [URL(fileURLWithPath: "/a")]).isEmpty)
  }
}

// MARK: - Preferences

@Suite("The Conversation settings and the choice of each session")
struct ConversationPreferencesTests {
  @Test("A setting a later build wrote, or one broken by hand, costs only itself")
  func tolerantDecoding() throws {
    let json = #"{"textSize":"gigantic","density":"compact","lightTheme":"paper","future":1}"#
    let appearance = try JSONDecoder().decode(
      ConversationAppearance.self, from: Data(json.utf8))
    #expect(appearance.textSize == .medium)
    #expect(appearance.density == .compact)
    #expect(appearance.lightTheme == "paper")
    #expect(appearance.defaultPresentation == .conversation)
  }

  @Test("The dark theme applies in dark mode only while the system is followed")
  func themeChoice() {
    var appearance = ConversationAppearance(lightTheme: "paper", darkTheme: "night")
    #expect(appearance.themeIdentifier(isDark: true) == "night")
    #expect(appearance.themeIdentifier(isDark: false) == "paper")
    appearance.followsSystemAppearance = false
    #expect(appearance.themeIdentifier(isDark: true) == "paper")
  }

  @Test("Text sizes step up and down, and stop at both ends")
  func sizes() {
    #expect(ConversationAppearance.TextSize.medium.larger == .large)
    #expect(ConversationAppearance.TextSize.extraLarge.larger == .extraLarge)
    #expect(ConversationAppearance.TextSize.small.smaller == .small)
  }

  @Test("A layout written before #38 reads with no choice, and gone sessions are forgotten")
  func layout() throws {
    let old = #"{"isSidebarVisible":true,"isInspectorVisible":false}"#
    var layout = try JSONDecoder().decode(WorkspaceLayout.self, from: Data(old.utf8))
    let kept = SessionID()
    let gone = SessionID()
    #expect(layout.presentation(of: kept, default: .conversation) == .conversation)
    layout.sessionPresentations = [kept.description: .terminal, gone.description: .terminal]
    layout.keepPresentations(of: [kept])
    #expect(layout.presentation(of: kept, default: .conversation) == .terminal)
    #expect(layout.sessionPresentations.count == 1)
    let roundTrip = try JSONDecoder().decode(
      WorkspaceLayout.self, from: JSONEncoder().encode(layout))
    #expect(roundTrip == layout)
  }
}
