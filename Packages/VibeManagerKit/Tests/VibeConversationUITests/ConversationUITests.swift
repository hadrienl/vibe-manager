import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

extension ConversationTheme: CustomTestStringConvertible {
  public var testDescription: String { id }
}

@Suite("The six themes")
struct ConversationThemeTests {
  @Test("Contrast is measured as WCAG does")
  func contrast() {
    let black: ThemeColor = "#000000"
    let white: ThemeColor = "#FFFFFF"
    #expect(abs(black.contrast(with: white) - 21) < 0.01)
    #expect(white.contrast(with: white) == 1)
    #expect(ThemeColor(hex: "12345") == nil)
    #expect(ThemeColor(hex: "#0A62D0")?.blue ?? 0 > 0.8)
  }

  @Test(
    "Every pair a reader must read passes, in every theme", arguments: ConversationTheme.builtIn)
  func legibility(theme: ConversationTheme) {
    for pair in theme.legibilityPairs {
      let ratio = pair.foreground.contrast(with: pair.background)
      #expect(
        ratio >= pair.minimum,
        "\(theme.id): \(pair.name) is \(String(format: "%.2f", ratio)):1, needs \(pair.minimum):1")
    }
  }

  @Test("Every accent reads on every theme it can be given to")
  func accents() {
    for accent in ConversationAppearance.Accent.allCases where ![.theme, .custom].contains(accent) {
      for base in ConversationTheme.builtIn {
        let theme = base.applying(ConversationAppearance(accent: accent))
        #expect(theme.onAccent.contrast(with: theme.accent) >= 4.5, "\(accent) on \(base.id)")
        #expect(theme.accent.contrast(with: theme.background) >= 3, "\(accent) on \(base.id)")
      }
    }
  }

  @Test("A colour of the user's own, with black or white on it, whichever reads")
  func customAccent() {
    let light = ConversationTheme.systemLight.applying(
      ConversationAppearance(accent: .custom, customAccent: "#FFD60A"))
    #expect(light.accent.hex == "#FFD60A")
    #expect(light.onAccent.hex == "#000000")
    let dark = ConversationTheme.systemDark.applying(
      ConversationAppearance(accent: .custom, customAccent: "#3A1D8C"))
    #expect(dark.onAccent.hex == "#FFFFFF")
    let none = ConversationTheme.systemLight.applying(ConversationAppearance(accent: .custom))
    #expect(none.accent == ConversationTheme.systemLight.accent)
  }

  @Test("The theme follows the system, and more contrast asked for gives High Contrast")
  func resolution() {
    let appearance = ConversationAppearance()
    #expect(
      ConversationTheme.resolve(appearance, isDark: true, increasedContrast: false).id
        == "system-dark")
    #expect(
      ConversationTheme.resolve(appearance, isDark: false, increasedContrast: true).id
        == "high-contrast")
    let paper = ConversationAppearance(lightTheme: "paper")
    #expect(
      ConversationTheme.resolve(paper, isDark: false, increasedContrast: true).id == "paper")
    let unknown = ConversationAppearance(lightTheme: "gone")
    #expect(
      ConversationTheme.resolve(unknown, isDark: false, increasedContrast: false).id
        == "system-light")
  }

  @Test("The user's fonts win over the theme's, the system's own by their design")
  func fonts() {
    var theme = ConversationTheme.paper.applying(ConversationAppearance(messageFont: "Charter"))
    #expect(theme.messageFontFamily == "Charter")
    theme = ConversationTheme.paper.applying(ConversationAppearance(messageFont: "SF Pro"))
    #expect(theme.messageFontFamily == nil)
    #expect(theme.fontStyle == .system)
    theme = ConversationTheme.systemLight.applying(ConversationAppearance(codeFont: "SF Mono"))
    #expect(theme.codeFontFamily == nil)
  }
}

@Suite("Markdown, parsed into blocks")
struct MarkdownDocumentTests {
  @Test("Headings, lists and task lists, quotes, code, tables, rules")
  func blocks() {
    let blocks = MarkdownDocument.blocks(
      from: """
        # Title
        Some **bold** and `code`.

        - [x] done
        - [ ] to do

        1. first

        > quoted

        ```swift
        let a = 1
        ```

        | Case | Before |
        |---|---|
        | replaced | twice |

        ---
        """)
    guard blocks.count == 8 else {
      Issue.record("\(blocks.count) blocks")
      return
    }
    #expect(blocks[0] == .heading(level: 1, runs: [InlineRun(text: "Title")]))
    guard case .paragraph(let runs) = blocks[1] else {
      Issue.record("no paragraph")
      return
    }
    #expect(runs.first { $0.isBold }?.text == "bold")
    #expect(runs.first { $0.isCode }?.text == "code")
    guard case .list(false, _, let items) = blocks[2] else {
      Issue.record("no list")
      return
    }
    #expect(items.map(\.checkbox) == [true, false])
    #expect(blocks[5] == .code(language: "swift", code: "let a = 1"))
    guard case .table(let header, let rows) = blocks[6] else {
      Issue.record("no table")
      return
    }
    #expect(header.map(MarkdownDocument.plainText) == ["Case", "Before"])
    #expect(rows.first?.map(MarkdownDocument.plainText) == ["replaced", "twice"])
    #expect(blocks[7] == .rule)
  }

  @Test("Only web and mail links survive; images are links, never loaded")
  func links() {
    let blocks = MarkdownDocument.blocks(
      from:
        "[a](https://example.com) [b](javascript:alert(1)) [c](file:///etc/passwd) ![pixel](https://tracker.example/p.gif)"
    )
    guard case .paragraph(let runs) = blocks.first else {
      Issue.record("no paragraph")
      return
    }
    let links = runs.compactMap(\.link).map(\.absoluteString)
    #expect(links == ["https://example.com", "https://tracker.example/p.gif"])
    #expect(runs.contains { $0.text == "pixel" })
  }
}

@Suite("Colouring code by its words")
struct SyntaxHighlighterTests {
  private func kinds(_ code: String, _ language: String?) -> [(String, SyntaxHighlighter.Kind)] {
    SyntaxHighlighter.segments(of: code, language: language)
      .filter { $0.kind != .plain }.map { ($0.text, $0.kind) }
  }

  @Test("Swift: keywords, strings, comments, numbers, types and calls")
  func swift() {
    let found = kinds(#"let tail = Tail(file: "a\"b", size: 42) // done"#, "swift")
    #expect(found.map(\.0) == ["let", "Tail", "\"a\\\"b\"", "42", "// done"])
    #expect(found.map(\.1) == [.keyword, .function, .string, .number, .comment])
  }

  @Test("The text is never changed, whatever the language — known, unknown or cut short")
  func lossless() {
    for (code, language) in [
      (#"echo "unterminated"#, "sh"), ("/* open comment", "c"), ("{\"a\": [1, true]}", "json"),
      ("anything at all", "brainfuck"), ("", "swift"), (#"x = "\"#, "python"),
    ] {
      let joined = SyntaxHighlighter.segments(of: code, language: language).map(\.text).joined()
      #expect(joined == code)
    }
  }

  @Test("A diff colours its lines by their sign")
  func diff() {
    let segments = SyntaxHighlighter.segments(of: "@@ -1 +1 @@\n-a\n+b\n c", language: "diff")
    #expect(segments.map(\.kind) == [.meta, .removed, .added, .plain])
  }
}

@Suite("Following the end of the conversation")
struct ConversationScrollStateTests {
  @Test("Following stops when the reader scrolls up, and what arrives meanwhile is counted")
  func rules() {
    var state = ConversationScrollState()
    let followed = state.blocksAppended(2)
    #expect(followed)
    state.bottomVisibilityChanged(false)
    let scrolled = state.blocksAppended(3)
    #expect(!scrolled)
    #expect(state.unseenCount == 3)
    state.bottomVisibilityChanged(true)
    #expect(state.unseenCount == 0)
    state.bottomVisibilityChanged(false)
    _ = state.blocksAppended(1)
    state.jumpedToBottom()
    #expect(state.isFollowing && state.unseenCount == 0)
    let nothing = state.blocksAppended(0)
    #expect(!nothing)
  }
}

@MainActor
@Suite("The conversation model and its composer")
struct ConversationModelTests {
  private final class Terminal: @unchecked Sendable {
    var written: [[UInt8]] = []
  }

  private func model(running: Bool = true) -> (ConversationModel, Terminal) {
    let model = ConversationModel(sessionID: SessionID())
    let terminal = Terminal()
    model.write = { terminal.written.append($0) }
    model.processRunning = { running }
    model.promptFormat = AgentPromptFormat(queueKey: [0x09], submitDelay: .zero)
    model.apply(ConversationSnapshot(availability: .available))
    return (model, terminal)
  }

  @Test("Send writes a bracketed paste, then Return; while the agent works, the queue key")
  func send() async {
    let (model, terminal) = model()
    model.draft = "hello"
    #expect(await model.send())
    #expect(terminal.written == [Array("\u{1B}[200~hello\u{1B}[201~".utf8), [0x0D]])
    #expect(model.draft.isEmpty)
    #expect(model.echoes.count == 1)
    model.activity = .working
    model.draft = "next"
    #expect(await model.send())
    #expect(terminal.written.last == [0x09])
  }

  @Test("Nothing is sent while the agent waits for an answer, nor to a stopped session")
  func closed() async {
    let (waiting, terminal) = model()
    waiting.activity = .awaitingUser(.approval)
    waiting.draft = "yes"
    #expect(waiting.composerState == .awaitingAnswer)
    #expect(await waiting.send() == false)
    #expect(terminal.written.isEmpty)
    let (stopped, _) = model(running: false)
    #expect(stopped.composerState == .stopped)
    stopped.draft = "hello"
    #expect(!stopped.canSend)
  }

  @Test("Nothing is sent while the agent is starting: its own screens would take the Return")
  func starting() async {
    let (model, terminal) = model()
    model.isAgentReady = false
    model.draft = "bonjour"
    #expect(model.composerState == .starting)
    #expect(await model.send() == false)
    #expect(terminal.written.isEmpty)
    model.isAgentReady = true
    #expect(await model.send())
  }

  @Test("An image produced while the session runs goes to the web view; the history's do not")
  func newImages() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeImages-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func image(_ name: String) throws -> ConversationEntry {
      let url = folder.appendingPathComponent(name)
      try Data([1]).write(to: url)
      return ConversationEntry(
        id: name,
        content: .tool(
          ToolCall(
            callID: name, kind: .image, state: .succeeded,
            parameters: [ToolParameter(.path, url.path)])))
    }
    let model = ConversationModel(sessionID: SessionID())
    var opened: [String] = []
    model.openInWebView = { url, automatically in
      if automatically { opened.append(url.lastPathComponent) }
    }
    let old = try image("old.png")
    model.apply(ConversationSnapshot(entries: [old], availability: .available))
    #expect(opened.isEmpty)
    model.apply(
      ConversationSnapshot(entries: [old, try image("new.png")], availability: .available))
    #expect(opened == ["new.png"])
    let page = folder.appendingPathComponent("page.html")
    try Data("<script>".utf8).write(to: page)
    let html = ToolCall(
      callID: "h", kind: .image, parameters: [ToolParameter(.path, page.path)])
    #expect(html.producedImage == nil)
  }

  @Test("The echo of a prompt goes once the transcript has it")
  func echo() async {
    let (model, _) = model()
    model.draft = "hello"
    await model.send()
    #expect(model.echoes.count == 1)
    model.apply(
      ConversationSnapshot(
        entries: [ConversationEntry(id: "u", content: .userPrompt("hello", attachments: 0))],
        availability: .available))
    #expect(model.echoes.isEmpty)
  }

  @Test("Two prompts sent before the first arrives: each echo waits for its own")
  func queuedEchoes() async {
    let (model, _) = model()
    model.draft = "first"
    await model.send()
    model.draft = "second"
    await model.send()
    let first = ConversationEntry(id: "1", content: .userPrompt("first", attachments: 0))
    model.apply(ConversationSnapshot(entries: [first], availability: .available))
    #expect(model.echoes.map(\.text) == ["second"])
    let second = ConversationEntry(id: "2", content: .userPrompt("second", attachments: 0))
    model.apply(ConversationSnapshot(entries: [first, second], availability: .available))
    #expect(model.echoes.isEmpty)
  }

  @Test("Failures and to-do lists are unfolded; the rest waits for the reader")
  func expansion() {
    let (model, _) = model()
    let failed = ConversationEntry(
      id: "f", content: .tool(ToolCall(callID: "f", kind: .shell, state: .failed(exitCode: 1))))
    let read = ConversationEntry(
      id: "r", content: .tool(ToolCall(callID: "r", kind: .read, state: .succeeded)))
    let todo = ConversationEntry(
      id: "t", content: .tool(ToolCall(callID: "t", kind: .todo, state: .succeeded)))
    #expect(model.isExpanded(.entry(failed)))
    #expect(!model.isExpanded(.entry(read)))
    #expect(model.isExpanded(.entry(todo)))
    model.setExpanded(true, for: "r")
    #expect(model.isExpanded(.entry(read)))
    model.appearance.expandsFailures = false
    #expect(!model.isExpanded(.entry(failed)))
  }

  @Test("The call a permission holds up is what the banner names")
  func pending() {
    let (model, _) = model()
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(
            id: "c",
            content: .tool(
              ToolCall(
                callID: "c", kind: .shell, state: .running,
                parameters: [ToolParameter(.command, "rm -rf .build")])))
        ], availability: .available))
    #expect(model.pendingCall == nil)
    model.activity = .awaitingUser(.approval)
    #expect(model.pendingCall?.parameter(.command) == "rm -rf .build")
  }

  @Test("Reasoning rows go when the settings hide them, and calls stop folding when asked")
  func appearance() {
    let (model, _) = model()
    let entries = [
      ConversationEntry(id: "r", content: .reasoning(nil)),
      ConversationEntry(id: "a", content: .tool(ToolCall(callID: "a", kind: .read))),
      ConversationEntry(id: "b", content: .tool(ToolCall(callID: "b", kind: .read))),
    ]
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    #expect(model.blocks.map(\.id) == ["r", "group:a"])
    model.appearance.showsReasoning = false
    model.appearance.groupsToolCalls = false
    #expect(model.blocks.map(\.id) == ["a", "b"])
  }
}
