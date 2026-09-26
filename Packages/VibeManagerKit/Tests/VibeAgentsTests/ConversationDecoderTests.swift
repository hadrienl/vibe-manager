import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// The fixtures are shaped after transcripts measured on Claude Code 2.1.275 to 2.1.282 and Codex
/// 0.156 and 0.157, with their words replaced: nothing a user wrote is kept in the repository.
@Suite("Reading a Claude Code transcript into a conversation")
struct ClaudeCodeConversationDecoderTests {
  private func decode(_ lines: [String], file: URL? = nil) -> [ConversationEntry] {
    let decoder = ClaudeCodeConversationDecoder(file: file)
    for line in lines { decoder.consume(Data(line.utf8)) }
    return decoder.entries
  }

  @Test("A prompt, the reasoning it kept to itself, an answer")
  func messages() {
    let entries = decode([
      #"{"type":"user","uuid":"u1","timestamp":"2026-09-25T10:00:00.123Z","message":{"role":"user","content":"Fix the tail"}}"#,
      #"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"thinking","thinking":"","signature":"x"}]}}"#,
      #"{"type":"assistant","uuid":"a2","message":{"id":"m1","content":[{"type":"text","text":"On it."}]}}"#,
      #"{"type":"attachment","uuid":"x1","attachment":{"type":"hook_success"}}"#,
      #"{"type":"cost-state","uuid":"x2","totalCostUSD":1}"#,
    ])
    #expect(entries.map(\.id) == ["u1", "a1", "a2"])
    #expect(entries[0].content == .userPrompt("Fix the tail", attachments: 0))
    #expect(entries[0].date != nil)
    #expect(entries[1].content == .reasoning(nil))
    #expect(entries[2].content == .agentText("On it."))
  }

  @Test("A command and its result: its output, its tests, its description")
  func command() {
    let entries = decode([
      #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test","description":"Run the tests"}}]}}"#,
      #"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]},"toolUseResult":{"stdout":"Executed 12 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds","stderr":"","interrupted":false}}"#,
    ])
    #expect(entries.count == 1)
    let call = entries[0].toolCall
    #expect(call?.kind == .shell)
    #expect(call?.state == .succeeded)
    #expect(call?.summary == "Run the tests")
    #expect(call?.parameter(.command) == "swift test")
    #expect(call?.facts.tests == TestOutcome(total: 12, failed: 0))
    #expect(call?.output?.text.contains("Executed 12 tests") == true)
  }

  @Test("A call runs until its result, fails with its exit code, or is refused")
  func states() {
    let use = { (id: String) in
      #"{"type":"assistant","uuid":"a-\#(id)","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"make"}}]}}"#
    }
    var entries = decode([use("t1")])
    #expect(entries[0].toolCall?.state == .running)
    entries = decode([
      use("t1"),
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Exit code 2\nmake: *** Error","is_error":true}]}}"#,
    ])
    #expect(entries[0].toolCall?.state == .failed(exitCode: 2))
    entries = decode([
      use("t1"),
      #"{"type":"user","uuid":"u","toolDenialKind":"permission-rule","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Refused by a hook","is_error":true}]}}"#,
    ])
    #expect(entries[0].toolCall?.state == .refused)
    entries = decode([
      use("t1"),
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"The user doesn't want to proceed with this tool use.","is_error":true}]}}"#,
    ])
    #expect(entries[0].toolCall?.state == .refused)
  }

  @Test("An interruption stops what was running, and says so")
  func interruption() {
    let entries = decode([
      #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 100"}}]}}"#,
      #"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
    ])
    #expect(entries[0].toolCall?.state == .interrupted)
    #expect(entries[1].content == .notice(.interrupted))
  }

  @Test("An edit keeps its patch, never the whole file it touched")
  func edit() {
    let original = String(repeating: "secret line\n", count: 1_000)
    let entries = decode([
      #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/Tail.swift","old_string":"a","new_string":"b"}}]}}"#,
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"toolUseResult":{"type":"update","filePath":"/p/Tail.swift","originalFile":"\#(original.replacingOccurrences(of: "\n", with: "\\n"))","structuredPatch":[{"oldStart":5,"oldLines":2,"newStart":5,"newLines":2,"lines":[" keep","-var offset = 0","+var offset: UInt64 = 0"]}]}}"#,
    ])
    let call = entries[0].toolCall
    #expect(call?.kind == .edit)
    #expect(call?.changes.first?.hunks.first?.lines.map(\.kind) == [.context, .removed, .added])
    #expect(call?.changes.first?.hunks.first?.lines[1].oldNumber == 6)
    #expect(call?.facts.addedLines == 1 && call?.facts.removedLines == 1)
    #expect(!String(describing: entries).contains("secret line"))
  }

  @Test("A file written from nothing is shown whole, as added")
  func creation() {
    let entries = decode([
      #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/p/New.swift","content":"a\nb"}}]}}"#,
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"toolUseResult":{"type":"create","filePath":"/p/New.swift","content":"a\nb\n","structuredPatch":[]}}"#,
    ])
    #expect(entries[0].toolCall?.kind == .create)
    #expect(entries[0].toolCall?.changes.first?.kind == .added)
    #expect(entries[0].toolCall?.facts.addedLines == 2)
  }

  @Test("The CLI's own messages become notices; side chains and meta lines are skipped")
  func notices() {
    let entries = decode([
      #"{"type":"user","uuid":"c","message":{"content":"<command-name>/model</command-name>\n<command-args>opus</command-args>"}}"#,
      #"{"type":"user","uuid":"b","message":{"content":"<bash-input>ls</bash-input>"}}"#,
      #"{"type":"user","uuid":"o","message":{"content":"<bash-stdout>a.swift</bash-stdout><bash-stderr></bash-stderr>"}}"#,
      #"{"type":"user","uuid":"m","isMeta":true,"message":{"content":"hidden"}}"#,
      #"{"type":"user","uuid":"s","isSidechain":true,"message":{"content":"sub-agent prompt"}}"#,
      #"{"type":"user","uuid":"r","message":{"content":"<system-reminder>x</system-reminder>"}}"#,
      #"{"type":"assistant","uuid":"e","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: overloaded"}]}}"#,
      #"{"type":"system","uuid":"k","subtype":"compact_boundary"}"#,
      #"{"type":"system","uuid":"w","subtype":"away_summary","content":"While you were away"}"#,
      #"{"type":"system","uuid":"d","subtype":"turn_duration","durationMs":12}"#,
    ])
    #expect(
      entries.map(\.content) == [
        .notice(.command("/model opus")),
        .notice(.shell(command: "ls", output: "a.swift")),
        .notice(.error("API Error: overloaded")),
        .notice(.compacted),
        .notice(.information("While you were away")),
      ])
  }

  @Test("A sub-agent points at its own transcript, a to-do list counts what is done")
  func subagentAndTodos() {
    let file = URL(fileURLWithPath: "/projects/p/abc.jsonl")
    let entries = decode(
      [
        #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Review","prompt":"…"}},{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"A","status":"completed"},{"content":"B","status":"pending"}]}}]}}"#,
        #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]},"toolUseResult":{"agentId":"a9","status":"completed"}}"#,
      ], file: file)
    #expect(entries[0].toolCall?.subTranscript?.path == "/projects/p/abc/subagents/agent-a9.jsonl")
    #expect(entries[1].toolCall?.kind == .todo)
    #expect(entries[1].toolCall?.facts.resultCount == 1)
    #expect(entries[1].toolCall?.facts.lineCount == 2)
    #expect(entries[1].id == "t2")
  }

  @Test("Prompts with images count them, MCP calls name their server")
  func imagesAndMCP() {
    let entries = decode([
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"What is this?"},{"type":"image","source":{"type":"base64","data":"AAAA"}}]}}"#,
      #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"t","name":"mcp__github__issues","input":{"action":"get"}}]}}"#,
    ])
    #expect(entries[0].content == .userPrompt("What is this?", attachments: 1))
    #expect(entries[1].toolCall?.kind == .mcp(server: "github", tool: "issues"))
    #expect(entries[1].toolCall?.parameter(.arguments) == #"{"action":"get"}"#)
  }

  @Test("A line that is not JSON, or cut short, is skipped")
  func garbage() {
    #expect(decode(["not json", #"{"type":"user","uuid":"x","message":{"content":"#]).isEmpty)
  }
}

@Suite("Reading a Codex rollout into a conversation")
struct CodexConversationDecoderTests {
  private func decode(_ lines: [String]) -> [ConversationEntry] {
    let decoder = CodexConversationDecoder()
    for line in lines { decoder.consume(Data(line.utf8)) }
    return decoder.entries
  }

  private func item(_ json: String) -> String {
    #"{"timestamp":"2026-09-25T10:00:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":\#(json)}}"#
  }

  @Test("Messages, without the environment Codex hands the model")
  func messages() {
    let entries = decode([
      item(
        #"{"type":"UserMessage","id":"u","content":[{"type":"text","text":"<environment_context>x</environment_context>"},{"type":"text","text":"Fix it"}]}"#
      ),
      item(#"{"type":"Reasoning","id":"r","summary_text":[],"raw_content":[]}"#),
      item(
        #"{"type":"AgentMessage","id":"a","content":[{"type":"Text","text":"Done."}],"phase":"final"}"#
      ),
    ])
    #expect(
      entries.map(\.content) == [
        .userPrompt("Fix it", attachments: 0), .reasoning(nil), .agentText("Done."),
      ])
  }

  @Test("A command is a read, a search or a listing when Codex parsed it as one")
  func commands() {
    let entries = decode([
      item(
        #"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","sed -n 1,20p a.swift"],"parsed_cmd":[{"type":"read","cmd":"sed -n 1,20p a.swift","name":"a.swift","path":"/p/a.swift"}],"status":"completed","exit_code":0,"aggregated_output":"…"}"#
      ),
      item(
        #"{"type":"CommandExecution","id":"c2","command":["/bin/zsh","-lc","rg Tail"],"parsed_cmd":[{"type":"search","cmd":"rg Tail","query":"Tail","path":null}],"status":"completed","exit_code":0,"aggregated_output":"a\nb"}"#
      ),
      item(
        #"{"type":"CommandExecution","id":"c3","command":["/bin/zsh","-lc","make"],"parsed_cmd":[{"type":"unknown","cmd":"make"}],"status":"failed","exit_code":2,"aggregated_output":"error","duration":{"secs":3,"nanos":500000000}}"#
      ),
    ])
    #expect(entries.map { $0.toolCall?.kind } == [.read, .search, .shell])
    #expect(entries[0].toolCall?.parameter(.path) == "/p/a.swift")
    #expect(entries[1].toolCall?.parameter(.pattern) == "Tail")
    #expect(entries[1].toolCall?.facts.resultCount == 2)
    #expect(entries[2].toolCall?.state == .failed(exitCode: 2))
    #expect(entries[2].toolCall?.parameter(.command) == "make")
    #expect(entries[2].toolCall?.facts.duration == .milliseconds(3_500))
  }

  @Test("A file change keeps its diff, per file")
  func fileChange() {
    let entries = decode([
      item(
        #"{"type":"FileChange","id":"f","status":"completed","changes":{"/p/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-a\n+b"},"/p/b.swift":{"type":"add","unified_diff":"@@ -0,0 +1,2 @@\n+x\n+y"}}}"#
      )
    ])
    let call = entries[0].toolCall
    #expect(call?.kind == .edit)
    #expect(call?.changes.map(\.kind) == [.modified, .added])
    #expect(call?.facts.addedLines == 3 && call?.facts.removedLines == 1)
  }

  @Test("A call is running until its output is written, then its item takes its place")
  func running() {
    let start =
      #"{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_1","name":"exec","input":"{\"cmd\":\"swift test\"}"}}"#
    #expect(
      decode([
        item(#"{"type":"UserMessage","id":"u","content":[{"type":"text","text":"go"}]}"#), start,
      ]).last?.toolCall?.state == .running)
    let done = decode([
      item(#"{"type":"UserMessage","id":"u","content":[{"type":"text","text":"go"}]}"#), start,
      #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_1","output":"ok"}}"#,
      item(
        #"{"type":"CommandExecution","id":"c1","command":"swift test","parsed_cmd":[],"status":"completed","exit_code":0,"aggregated_output":"ok"}"#
      ),
    ])
    #expect(done.count == 2)
    #expect(done[1].toolCall?.state == .succeeded)
    let aborted = decode([
      item(#"{"type":"UserMessage","id":"u","content":[{"type":"text","text":"go"}]}"#), start,
      #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ])
    #expect(aborted[1].toolCall?.state == .interrupted)
    #expect(aborted[2].content == .notice(.interrupted))
  }

  @Test("A generated image keeps where it was saved, never its bytes")
  func generatedImage() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeImage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = folder.appendingPathComponent("plane.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
    let entries = decode([
      item(
        #"{"type":"Extension","kind":"image_gen.generation","id":"x","status":"completed","revisedPrompt":"a plane","result":"iVBORw0KGgoAAAANSUhEUg","savedPath":"\#(png.path)"}"#
      )
    ])
    let call = try #require(entries.first?.toolCall)
    #expect(call.kind == .image)
    #expect(call.producedImage == png)
    #expect(call.parameter(.prompt) == "a plane")
    #expect(!String(describing: entries).contains("iVBORw0KGgo"))
  }

  @Test("An MCP call, a failed one")
  func mcp() {
    let entries = decode([
      item(
        #"{"type":"McpToolCall","id":"m","server":"github","tool":"issues","arguments":{"action":"get"},"status":"failed","result":{"content":[{"type":"text","text":"Not found"}]}}"#
      )
    ])
    #expect(entries[0].toolCall?.kind == .mcp(server: "github", tool: "issues"))
    #expect(entries[0].toolCall?.state == .failed(exitCode: nil))
    #expect(entries[0].toolCall?.output?.text == "Not found")
  }

  @Test("An older rollout shows its messages, and says its tools are missing")
  func olderFormat() {
    let entries = decode([
      #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}}"#,
    ])
    #expect(
      entries.map(\.content) == [
        .notice(.olderFormat), .userPrompt("hello", attachments: 0), .agentText("hi"),
      ])
  }
}

@Suite("Following a transcript as it grows")
struct FileTranscriptTailTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeTail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func append(_ text: String, to file: URL) throws {
    if let handle = try? FileHandle(forWritingTo: file) {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
      try handle.close()
    } else {
      try Data(text.utf8).write(to: file)
    }
  }

  @Test("Only whole lines, resumed where the last reading stopped")
  func wholeLines() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("t.jsonl")
    try append("one\ntw", to: file)
    var reader = TranscriptLineReader(file: file)
    #expect(reader.readAvailable().lines.map { String(decoding: $0, as: UTF8.self) } == ["one"])
    try append("o\nthree\n", to: file)
    #expect(
      reader.readAvailable().lines.map { String(decoding: $0, as: UTF8.self) } == ["two", "three"])
    #expect(reader.readAvailable().lines.isEmpty)
  }

  @Test("A file replaced under its name is read again from its start")
  func replaced() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("t.jsonl")
    try append("old one\nold two\n", to: file)
    var reader = TranscriptLineReader(file: file)
    _ = reader.readAvailable()
    try FileManager.default.removeItem(at: file)
    try append("new\n", to: file)
    let reading = reader.readAvailable()
    #expect(reading.wasReset)
    #expect(reading.lines.map { String(decoding: $0, as: UTF8.self) } == ["new"])
  }

  @Test("Following: what is there, what is written next, and a file that appears later")
  func follow() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("t.jsonl")
    let tail = FileTranscriptTail(pollInterval: .milliseconds(50))
    var iterator = tail.follow(file).makeAsyncIterator()
    // Nothing yet: the first reading says so, empty.
    guard case .lines(let first) = await iterator.next() else {
      Issue.record("no first reading")
      return
    }
    #expect(first.isEmpty)
    try append("a\nb\n", to: file)
    var received: [String] = []
    while received.count < 2, let chunk = await iterator.next() {
      if case .lines(let lines) = chunk {
        received += lines.map { String(decoding: $0, as: UTF8.self) }
      }
    }
    #expect(received == ["a", "b"])
    try append("c\n", to: file)
    while received.count < 3, let chunk = await iterator.next() {
      if case .lines(let lines) = chunk {
        received += lines.map { String(decoding: $0, as: UTF8.self) }
      }
    }
    #expect(received == ["a", "b", "c"])
  }
}

@Suite("The mock agent's conversation")
struct MockConversationTests {
  @Test("With a transcript folder, the mock writes its conversation as Claude Code does")
  func transcript() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeMockTranscript-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let provider = MockAgentProvider(environment: ["VIBE_MOCK_TRANSCRIPT_DIRECTORY": folder.path])
    let agent = SessionAgentConfiguration(providerID: "mock", resumeIdentifier: "m1")
    let session = WorkSession(name: "Mock", agent: agent)
    #expect(provider.conversationFiles(for: agent, in: session, hint: nil).isEmpty)
    let script = try #require(MockAgentProvider.defaultScriptURL())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      script.path, "--session-id", "m1", "--transcript-dir", folder.path, "--prompt", "hello",
    ]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let files = provider.conversationFiles(for: agent, in: session, hint: nil)
    #expect(files.count == 1)
    let decoder = provider.conversationDecoder(for: files[0])
    for line in await FileTranscriptTail().read(files[0]) { decoder.consume(line) }
    let expected: [ConversationEntry.Content] = [
      .userPrompt("hello", attachments: 0), .agentText("Mock received: hello"),
    ]
    #expect(decoder.entries.map(\.content) == expected)
  }
}
