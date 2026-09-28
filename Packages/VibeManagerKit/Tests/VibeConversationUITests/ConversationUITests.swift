import AppKit
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

@Suite("Prose, selectable from one paragraph to the next")
@MainActor
struct MarkdownProseTests {
  private let message = """
    # Title
    First paragraph, with a [link](https://example.com).

    - one
    - [x] done

    > quoted

    ```swift
    let a = 1
    ```

    Last paragraph.
    """

  @Test("Prose that follows prose is one segment; code, tables and rules cut it")
  func segments() {
    let segments = MarkdownProse.segments(MarkdownDocument.blocks(from: message))
    guard segments.count == 3, case .prose(let first) = segments[0],
      case .block(.code) = segments[1], case .prose(let last) = segments[2]
    else {
      Issue.record("\(segments)")
      return
    }
    #expect(first.count == 4)
    #expect(last.count == 1)
    // A list holding code is not prose: its code block needs its own view.
    let list = MarkdownDocument.blocks(from: "- item\n\n  ```\n  code\n  ```")
    #expect(MarkdownProse.segments(list) == list.map { .block($0) })
  }

  @Test("One string holds every paragraph of the run, a line each, markers included")
  func text() throws {
    let blocks = MarkdownDocument.blocks(from: message)
    guard case .prose(let prose) = MarkdownProse.segments(blocks).first else {
      Issue.record("no prose")
      return
    }
    let string = MarkdownProse.attributedString(
      prose, theme: .systemLight, size: 14, spacing: 10)
    #expect(
      string.string
        == "Title\nFirst paragraph, with a link.\n•\tone\n☑\tdone\nquoted")
    let link = (string.string as NSString).range(of: "link")
    #expect(
      string.attribute(.link, at: link.location, effectiveRange: nil) as? URL
        == URL(string: "https://example.com"))
    let quote = (string.string as NSString).range(of: "quoted")
    let style = try #require(
      string.attribute(.paragraphStyle, at: quote.location, effectiveRange: nil)
        as? NSParagraphStyle)
    #expect(
      string.attribute(.quoteBars, at: quote.location, effectiveRange: nil) as? [CGFloat] == [0])
    #expect(style.headIndent > 0)
    // The stack spaces what follows the run, not the run itself.
    #expect(style.paragraphSpacing == 0)
    let item = (string.string as NSString).range(of: "one")
    let itemStyle = try #require(
      string.attribute(.paragraphStyle, at: item.location, effectiveRange: nil)
        as? NSParagraphStyle)
    #expect(itemStyle.headIndent > 0)
    #expect(itemStyle.firstLineHeadIndent == 0)
  }

  @Test("The text view is as tall as its text at the width it is given")
  func height() {
    let view = ProseTextView()
    view.show(
      MarkdownProse.attributedString(
        MarkdownDocument.blocks(from: "One.\n\nTwo.\n\nThree."), theme: .systemLight, size: 14,
        spacing: 10))
    let wide = view.height(forWidth: 600)
    let narrow = view.height(forWidth: 20)
    #expect(wide > 40)
    #expect(narrow > wide)
    view.setSelectedRange(NSRange(location: 0, length: view.string.count))
    #expect(view.selectedRanges.first?.rangeValue.length == view.string.count)
  }

  @Test("The Edit menu copies the message whose text holds the keyboard, and only while it does")
  func focusedMarkdown() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let view = ProseTextView()
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    view.markdown = "**One**"
    let other = NSTextField()
    window.contentView?.addSubview(view)
    window.contentView?.addSubview(other)
    #expect(window.makeFirstResponder(view))
    #expect(FocusedMarkdown.shared.markdown == "**One**")
    view.markdown = "**One** and more"
    #expect(FocusedMarkdown.shared.markdown == "**One** and more")
    #expect(window.makeFirstResponder(other))
    #expect(FocusedMarkdown.shared.markdown == nil)
    #expect(window.makeFirstResponder(view))
    view.removeFromSuperview()
    #expect(FocusedMarkdown.shared.markdown == nil)
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
    state.scrolled(distanceToBottom: 300, contentMovedDown: 300)
    let scrolled = state.blocksAppended(3)
    #expect(!scrolled)
    #expect(state.unseenCount == 3)
    state.scrolled(distanceToBottom: 0, contentMovedDown: -300)
    #expect(state.isFollowing && state.unseenCount == 0)
    state.scrolled(distanceToBottom: 300, contentMovedDown: 300)
    _ = state.blocksAppended(1)
    state.jumpedToBottom()
    #expect(state.isFollowing && state.unseenCount == 0)
    let nothing = state.blocksAppended(0)
    #expect(!nothing)
  }

  @Test("A block growing the end, before the view follows it, does not stop the following")
  func growthKeepsFollowing() {
    var state = ConversationScrollState()
    // The block is laid out below the visible part; the top of the content has not moved.
    state.scrolled(distanceToBottom: 400, contentMovedDown: 0)
    let followed = state.blocksAppended(1)
    #expect(followed)
    #expect(state.unseenCount == 0)
  }

  @Test("Coming back to the end, or near it, clears what was counted")
  func backAtTheEnd() {
    var state = ConversationScrollState()
    state.scrolled(distanceToBottom: 500, contentMovedDown: 500)
    _ = state.blocksAppended(32)
    #expect(state.unseenCount == 32)
    state.scrolled(distanceToBottom: 10, contentMovedDown: -490)
    #expect(state.isFollowing && state.unseenCount == 0)
  }

  @MainActor
  @Test("The model tells a scroll up from content growing at the end")
  func geometry() {
    let model = ConversationModel(sessionID: SessionID())
    let viewport = 600.0
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -400, width: 800, height: 1000), viewportHeight: viewport)
    #expect(model.scroll.isFollowing)
    // A block arrives below: the content is taller, its top has not moved.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -400, width: 800, height: 1500), viewportHeight: viewport)
    #expect(model.scroll.isFollowing)
    // The reader scrolls up.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -300, width: 800, height: 1500), viewportHeight: viewport)
    #expect(!model.scroll.isFollowing)
  }

  @MainActor
  @Test("Left past the end of its content, the view is sent back to it, once per landing")
  func pastTheEnd() {
    let model = ConversationModel(sessionID: SessionID())
    let viewport = 600.0
    let asked = model.scrollToBottomRequest
    // At the end, or bounced a little past it: nothing to do.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -400, width: 800, height: 1000), viewportHeight: viewport)
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -440, width: 800, height: 1000), viewportHeight: viewport)
    #expect(model.scrollToBottomRequest == asked)
    // Rows measured shorter than estimated: the content now ends above the viewport.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -1200, width: 800, height: 1000), viewportHeight: viewport)
    #expect(model.scrollToBottomRequest == asked + 1)
    // Still there on the next reading: asked only once.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -1100, width: 800, height: 1000), viewportHeight: viewport)
    #expect(model.scrollToBottomRequest == asked + 1)
    // Back at the end, then past it again: asked again.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -400, width: 800, height: 1000), viewportHeight: viewport)
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: -1200, width: 800, height: 1000), viewportHeight: viewport)
    #expect(model.scrollToBottomRequest == asked + 2)
    // Content shorter than the viewport is never past its end.
    model.scrollGeometryChanged(
      contentFrame: CGRect(x: 0, y: 0, width: 800, height: 200), viewportHeight: viewport)
    #expect(model.scrollToBottomRequest == asked + 2)
  }
}

@Suite("A question answered, read back from its call")
struct AskedQuestionTests {
  private func call(_ parameters: [ToolParameter]) -> ToolCall {
    ToolCall(callID: "t", kind: .question, parameters: parameters)
  }

  @Test("An option, several, or the user's own words")
  func chosen() {
    let questions = AskedQuestion.all(
      in: call([
        ToolParameter(.question, "Tea?"), ToolParameter(.arguments, "Tea"),
        ToolParameter(.arguments, "Coffee"), ToolParameter(.answer, "Coffee"),
        ToolParameter(.question, "Extras?"), ToolParameter(.multipleChoices, "true"),
        ToolParameter(.arguments, "Milk"), ToolParameter(.arguments, "Sugar"),
        ToolParameter(.answer, "Milk, Sugar"),
        ToolParameter(.question, "Cup?"), ToolParameter(.arguments, "Small"),
        ToolParameter(.answer, "A mug"),
        ToolParameter(.question, "Later?"), ToolParameter(.arguments, "Yes"),
      ]))
    #expect(questions.map(\.chosen) == [["Coffee"], ["Milk", "Sugar"], [], []])
    #expect(questions.map(\.otherAnswer) == [nil, nil, "A mug", nil])
    #expect(questions[1].allowsMultipleChoices)
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

  @Test("A request for the keyboard waits for the composer, and is spent once (#105)")
  func focusRequest() {
    let (model, _) = model()
    #expect(!model.takePendingFocusRequest())
    model.requestComposerFocus()
    model.requestComposerFocus()
    #expect(model.focusComposerRequest == 2)
    #expect(model.takePendingFocusRequest())
    #expect(!model.takePendingFocusRequest())
    model.attach([URL(fileURLWithPath: "/Users/me/a.png")])
    #expect(model.takePendingFocusRequest())
  }

  @Test("Only a composer that can be typed into accepts the keyboard (#105)")
  func acceptsInput() {
    let (ready, _) = model()
    #expect(ready.acceptsInput)
    ready.activity = .awaitingUser(.approval)
    #expect(!ready.acceptsInput)
    let (stopped, _) = model(running: false)
    #expect(!stopped.acceptsInput)
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

  private final class Answers: @unchecked Sendable {
    var given: [(AgentAnswer, AgentRequestID)] = []
    var sends = true
  }

  private func asking(
    _ questions: [AgentQuestion], answers kinds: Set<AgentAnswerKind>
  ) -> (ConversationModel, Terminal, Answers, AgentRequestID) {
    let (model, terminal) = model()
    let id = AgentRequestID(sessionID: model.sessionID, key: "q")
    let request = AgentRequest(
      id: id, receivedAt: Date(), kind: .question, content: .questions(questions),
      reference: AgentToolReference(tool: "AskUserQuestion"), isShown: true)
    let answers = Answers()
    model.pendingRequest = { ConversationRequest(request: request, answers: kinds, isSending: false) }
    model.answerRequest = { answer, id in
      answers.given.append((answer, id))
      return answers.sends
    }
    model.activity = .awaitingUser(.question)
    return (model, terminal, answers, id)
  }

  private static let colour = AgentQuestion(
    header: "Colour", text: "Which colour?", options: [.init(label: "Red"), .init(label: "Blue")])

  @Test("A single question is answered by its option, at once, as the palette would")
  func chooseOption() async throws {
    let (model, _, answers, id) = asking([Self.colour], answers: [.chooseOption, .writeText])
    model.choose(option: 1, ofQuestion: 0)
    while answers.given.isEmpty { await Task.yield() }
    #expect(answers.given.first?.0 == .answers([.option(1)]))
    #expect(answers.given.first?.1 == id)
  }

  @Test("Several questions are answered together, once each has its option")
  func chooseSeveral() async {
    let size = AgentQuestion(
      header: "Size", text: "Which size?", options: [.init(label: "S"), .init(label: "L")])
    let (model, _, answers, _) = asking([Self.colour, size], answers: [.chooseOption])
    model.choose(option: 0, ofQuestion: 0)
    #expect(!model.canSendChoices)
    #expect(model.isChosen(option: 0, ofQuestion: 0))
    model.choose(option: 1, ofQuestion: 1)
    #expect(model.canSendChoices)
    model.sendChoices()
    while answers.given.isEmpty { await Task.yield() }
    #expect(answers.given.first?.0 == .answers([.option(0), .option(1)]))
    // Of several questions, the composer writes none of them.
    #expect(model.composerState == .awaitingAnswer)
  }

  @Test("A question of several choices ticks and unticks its boxes, then goes with the others")
  func chooseMultiple() async {
    let features = AgentQuestion(
      header: "Features", text: "Which ones?",
      options: [.init(label: "A"), .init(label: "B"), .init(label: "C")],
      allowsMultipleChoices: true)
    let (model, _, answers, _) = asking(
      [Self.colour, features], answers: [.chooseOption, .chooseOptions, .writeText])
    model.choose(option: 1, ofQuestion: 0)
    model.choose(option: 0, ofQuestion: 1)
    model.choose(option: 2, ofQuestion: 1)
    model.choose(option: 0, ofQuestion: 1)
    #expect(!model.isChosen(option: 0, ofQuestion: 1))
    #expect(model.isChosen(option: 2, ofQuestion: 1))
    #expect(model.canSendChoices)
    model.choose(option: 2, ofQuestion: 1)
    #expect(!model.canSendChoices)
    model.choose(option: 1, ofQuestion: 1)
    model.sendChoices()
    while answers.given.isEmpty { await Task.yield() }
    #expect(answers.given.first?.0 == .answers([.option(1), .options([1])]))
  }

  @Test("The first choice redraws its option: what the view read of the choices is observed")
  func firstChoiceObserved() {
    let (model, _, _, _) = asking(
      [Self.colour, Self.colour], answers: [.chooseOption, .writeText])
    final class Flag: @unchecked Sendable { var changed = false }
    let flag = Flag()
    withObservationTracking {
      _ = model.isChosen(option: 1, ofQuestion: 0)
    } onChange: {
      flag.changed = true
    }
    model.choose(option: 1, ofQuestion: 0)
    #expect(flag.changed)
  }

  @Test("Alone, a question of several choices waits for its Send, and the composer stays closed")
  func singleMultiple() {
    let features = AgentQuestion(
      header: nil, text: "Which ones?", options: [.init(label: "A"), .init(label: "B")],
      allowsMultipleChoices: true)
    let (model, _, _, _) = asking([features], answers: [.chooseOption, .chooseOptions, .writeText])
    #expect(model.composerState == .awaitingAnswer)
    model.choose(option: 0, ofQuestion: 0)
    #expect(model.isChosen(option: 0, ofQuestion: 0))
    #expect(model.canSendChoices)
  }

  @Test("The composer writes a question's free answer, never a prompt, while it is asked")
  func freeAnswer() async {
    let (model, terminal, answers, _) = asking([Self.colour], answers: [.chooseOption, .writeText])
    #expect(model.composerState == .answeringQuestion)
    model.draft = "  Green  "
    #expect(model.canSend)
    #expect(await model.send())
    #expect(answers.given.first?.0 == .answers([.text("Green")]))
    #expect(terminal.written.isEmpty)
    #expect(model.draft.isEmpty)
  }

  @Test("A free answer that could not be typed stays in the composer")
  func freeAnswerKept() async {
    let (model, _, answers, _) = asking([Self.colour], answers: [.chooseOption, .writeText])
    answers.sends = false
    model.draft = "Green"
    #expect(await model.send() == false)
    #expect(model.draft == "Green")
  }

  @Test("A permission's buttons go under the call it names, not the last one waiting")
  func permissionUnderItsCall() {
    let (model, _) = model()
    let first = ToolCall(callID: "t1", kind: .shell, parameters: [ToolParameter(.command, "rm -r build")])
    let last = ToolCall(callID: "t2", kind: .shell, parameters: [ToolParameter(.command, "ls")])
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "e1", content: .tool(first)),
          ConversationEntry(id: "e2", content: .tool(last)),
        ], availability: .available))
    let request = AgentRequest(
      id: AgentRequestID(sessionID: model.sessionID, key: "p"), receivedAt: Date(),
      kind: .approval,
      content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: "rm -r build")),
      reference: AgentToolReference(tool: "Bash"), isShown: true)
    model.pendingRequest = {
      ConversationRequest(request: request, answers: [.allowOnce, .deny], isSending: false)
    }
    model.answerRequest = { _, _ in true }
    model.activity = .awaitingUser(.approval)
    #expect(model.pendingCall?.callID == "t2")
    #expect(model.request(for: first) != nil)
    #expect(model.request(for: last) == nil)
  }

  @Test("A question only its terminal can answer leaves the options and the composer closed")
  func terminalOnly() async {
    let (model, _, answers, _) = asking([Self.colour], answers: [])
    #expect(model.composerState == .awaitingAnswer)
    model.choose(option: 0, ofQuestion: 0)
    model.draft = "Green"
    #expect(await model.send() == false)
    await Task.yield()
    #expect(answers.given.isEmpty)
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

  @Test("A prompt sent before the previous one's Return is refused: they would be one")
  func sendWhileSubmitting() async {
    let (model, terminal) = model()
    model.promptFormat = AgentPromptFormat(submitDelay: .milliseconds(200))
    model.draft = "first"
    let first = Task { await model.send() }
    while !model.isSubmitting { await Task.yield() }
    model.draft = "second"
    #expect(!model.canSend)
    #expect(await model.send() == false)
    #expect(await first.value)
    #expect(!model.isSubmitting)
    #expect(terminal.written == [Array("\u{1B}[200~first\u{1B}[201~".utf8), [0x0D]])
    #expect(model.draft == "second")
    #expect(model.canSend)
  }

  @Test("Read again, a conversation stays on screen until the new reading holds all of it")
  func rereading() {
    let model = ConversationModel(sessionID: SessionID())
    let said = ["one", "two", "three"].map {
      ConversationEntry(id: $0, content: .agentText($0))
    }
    let (first, _) = AsyncStream<ConversationSnapshot>.makeStream()
    model.follow(first)
    // Read for the first time, what arrives is shown as it arrives.
    model.received(ConversationSnapshot(entries: [said[0]], availability: .loading))
    #expect(model.blocks.map(\.id) == ["one"])
    model.received(ConversationSnapshot(entries: Array(said[..<2]), availability: .available))

    let (again, _) = AsyncStream<ConversationSnapshot>.makeStream()
    model.follow(again)
    model.received(ConversationSnapshot(entries: [said[0]], availability: .loading))
    #expect(model.blocks.map(\.id) == ["one", "two"])
    #expect(model.snapshot.availability == .available)
    model.received(ConversationSnapshot(entries: said, availability: .available))
    #expect(model.blocks.map(\.id) == ["one", "two", "three"])
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
