import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

private let commands = [
  AgentCommand(
    name: "prisme-ai:debug-events", invocation: "/prisme-ai:debug-events",
    description: "Trace an execution.", argumentHint: "[correlationId]", kind: .skill,
    origin: .plugin("prisme-ai")),
  AgentCommand(
    name: "debugger", invocation: "/debugger", description: "Debugs.", kind: .skill,
    origin: .user),
  AgentCommand(
    name: "compact", invocation: "/compact", description: "Free up context.", kind: .command,
    origin: .builtin),
]

@MainActor
private func readyModel(
  entries: [ConversationEntry] = [], list: [AgentCommand] = commands
) async -> (ConversationModel, Terminal) {
  let model = ConversationModel(sessionID: SessionID())
  let terminal = Terminal()
  model.write = { terminal.written.append($0) }
  model.processRunning = { true }
  model.promptFormat = AgentPromptFormat(
    textEntry: .plain, submitDelay: .zero, shellEntry: ShellEntry(switchDelay: .zero))
  model.apply(ConversationSnapshot(entries: entries, availability: .available))
  let index = AgentCommandIndex(list)
  model.readCommands = { index }
  model.refreshCommands()
  while model.commandIndex.isEmpty { await Task.yield() }
  return (model, terminal)
}

private final class Terminal: @unchecked Sendable {
  var written: [[UInt8]] = []
}

@MainActor
@Suite("The list of skills and commands in the composer (#219)")
struct ComposerCommandsTests {
  @Test("A `/` typed first opens the list; the text typed filters it; a space closes it")
  func opening() async {
    let (model, _) = await readyModel()
    #expect(model.commandSuggestions == nil)
    model.draft = "/"
    #expect(model.showsCommandSuggestions)
    #expect(
      model.commandSuggestions?.map(\.command.name) == [
        "debugger", "prisme-ai:debug-events", "compact",
      ])
    model.draft = "/debug"
    #expect(
      model.commandSuggestions?.map(\.command.name) == ["debugger", "prisme-ai:debug-events"])
    model.draft = "/zzz"
    #expect(model.commandSuggestions == [])
    #expect(model.showsCommandSuggestions)
    model.draft = "/debug now"
    #expect(model.commandSuggestions == nil)
    model.draft = "say /debug"
    #expect(model.commandSuggestions == nil)
  }

  @Test("Without a list read, `/` is text")
  func noList() {
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { true }
    model.apply(ConversationSnapshot(availability: .available))
    model.draft = "/"
    #expect(!model.showsCommandSuggestions)
  }

  @Test("↑ and ↓ move the selection within the list, back to the first when the text changes")
  func selection() async {
    let (model, _) = await readyModel()
    model.draft = "/"
    #expect(model.moveCommandSelection(by: -1))
    #expect(model.selectedCommandIndex == 0)
    #expect(model.moveCommandSelection(by: 1))
    #expect(model.moveCommandSelection(by: 1))
    #expect(model.moveCommandSelection(by: 1))
    #expect(model.selectedCommandIndex == 2)
    model.draft = "/d"
    #expect(model.selectedCommandIndex == 0)
    model.draft = "/zzz"
    #expect(model.moveCommandSelection(by: 1))
  }

  @Test("Inserting writes the invocation and a space, with the arguments' hint until typed")
  func inserting() async {
    let (model, _) = await readyModel()
    model.draft = "/debug"
    #expect(model.moveCommandSelection(by: 1))
    #expect(model.insertSelectedCommand())
    #expect(model.draft == "/prisme-ai:debug-events ")
    #expect(model.commandSuggestions == nil)
    #expect(model.insertedInvocation == "/prisme-ai:debug-events")
    #expect(model.pendingArgumentHint == "[correlationId]")
    model.draft += "3f2c"
    #expect(model.pendingArgumentHint == nil)
    #expect(model.insertedInvocation == "/prisme-ai:debug-events")
    model.draft = "/prisme-ai:debug"
    #expect(model.insertedInvocation == nil)
    // With nothing matching, nothing is inserted: Return sends the text as it is.
    model.draft = "/zzz"
    #expect(!model.insertSelectedCommand())
  }

  @Test("Escape closes the list for that command; erasing back to `/` opens it again")
  func dismissing() async {
    let (model, _) = await readyModel()
    model.draft = "/deb"
    #expect(model.dismissCommandSuggestions())
    #expect(!model.showsCommandSuggestions)
    #expect(model.draft == "/deb")
    model.draft = "/debu"
    #expect(!model.showsCommandSuggestions)
    #expect(!model.dismissCommandSuggestions())
    model.draft = "/"
    #expect(model.showsCommandSuggestions)
    model.draft = "/c"
    #expect(model.dismissCommandSuggestions())
    model.draft = ""
    model.draft = "/c"
    #expect(model.showsCommandSuggestions)
  }

  @Test("A message recalled from the history opens no list: ↑ keeps walking the history")
  func history() async {
    let (model, _) = await readyModel(entries: [
      ConversationEntry(id: "1", content: .userPrompt("/weird", attachments: 0))
    ])
    #expect(model.recallOlderPrompt())
    #expect(model.draft == "/weird")
    #expect(!model.showsCommandSuggestions)
    model.draft = "/weirdo"
    #expect(!model.showsCommandSuggestions)
    model.draft = ""
    model.draft = "/"
    #expect(model.showsCommandSuggestions)
  }

  @Test("The shell mode stays as it was: `!` opens no list")
  func shell() async {
    let (model, _) = await readyModel()
    model.draft = "!ls"
    #expect(model.commandSuggestions == nil)
    #expect(model.composerMode == .shell)
  }

  @Test("A skill sent is written as typed, and its command in the transcript confirms it")
  func sending() async {
    let (model, terminal) = await readyModel()
    model.draft = "/prisme-ai:debug-events 3f2c"
    #expect(await model.send())
    #expect(terminal.written == [Array("/prisme-ai:debug-events 3f2c".utf8), [0x0D]])
    #expect(model.echoes.count == 1)
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "c", content: .notice(.command("/prisme-ai:debug-events 3f2c")))
        ], availability: .available))
    #expect(model.echoes.isEmpty)
  }

  private func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled { await Task.yield() }
  }

  private static func commandWritten(_ command: String) -> ConversationSnapshot {
    ConversationSnapshot(
      entries: [ConversationEntry(id: "c", content: .notice(.command(command)))],
      availability: .available)
  }

  @Test(
    "A command not written at once waits in a panel of the terminal, shown until it is written",
    .timeLimit(.minutes(1)))
  func terminalPanel() async {
    let (model, _) = await readyModel()
    model.draft = "/mcp"
    #expect(await model.send())
    #expect(model.terminalPanel == nil)
    await until { model.terminalPanel != nil }
    #expect(model.terminalPanel?.command == "/mcp")
    // Past ten seconds, still waited for: the panel may stay open long.
    #expect(
      model.echoes.first?.confirmationDeadline ?? .distantPast > Date().addingTimeInterval(60))
    model.apply(Self.commandWritten("/mcp"))
    #expect(model.terminalPanel == nil)
    #expect(model.echoes.isEmpty)
  }

  @Test(
    "Closing the panel from the conversation types Escape and drops the command's echo",
    .timeLimit(.minutes(1)))
  func closingThePanel() async {
    let (model, terminal) = await readyModel()
    model.draft = "/model"
    #expect(await model.send())
    await until { model.terminalPanel != nil }
    terminal.written = []
    await model.closeTerminalPanel()
    #expect(model.terminalPanel == nil)
    #expect(model.echoes.isEmpty)
    #expect(terminal.written == [[0x1B]])
  }

  @Test(
    "A command written at once, a message, or the agent at work open no panel",
    .timeLimit(.minutes(1)))
  func noPanel() async throws {
    let (model, _) = await readyModel()
    model.draft = "/prisme-ai:debug-events 3f2c"
    #expect(await model.send())
    model.apply(Self.commandWritten("/prisme-ai:debug-events 3f2c"))
    model.draft = "hello"
    #expect(await model.send())
    try await Task.sleep(for: ConversationModel.terminalPanelDelay * 2)
    #expect(model.terminalPanel == nil)

    model.draft = "/mcp"
    #expect(await model.send())
    await until { model.terminalPanel != nil }
    model.activity = .working
    #expect(model.terminalPanel == nil)
  }

  @Test(
    "Leaving for the terminal ends the panel's block, and the command is no longer waited for",
    .timeLimit(.minutes(1)))
  func leavingForTheTerminal() async {
    let (model, terminal) = await readyModel()
    model.draft = "/mcp"
    #expect(await model.send())
    await until { model.terminalPanel != nil }
    terminal.written = []
    model.leaveTerminalPanel()
    #expect(model.terminalPanel == nil)
    #expect(model.echoes.isEmpty)
    // Nothing typed: the panel is finished in the terminal.
    #expect(terminal.written.isEmpty)
  }

  @Test(
    "Read for the first time, the list opens at once and says it is on its way",
    .timeLimit(.minutes(1)))
  func firstReading() async {
    let index = AgentCommandIndex(commands)
    let list = ComposerCommands()
    let gate = AsyncStream<Void>.makeStream()
    list.read = {
      for await _ in gate.stream { break }
      return index
    }
    list.update(text: "/", isEnabled: true)
    #expect(list.isShowing)
    #expect(list.isReading)
    #expect(list.suggestions == [])
    gate.continuation.yield()
    await until { !list.isReading }
    #expect(list.suggestions?.count == 3)
  }

  @Test(
    "The panel seen on the block's screen, then gone, closes the block", .timeLimit(.minutes(1)))
  func panelGone() async {
    let (model, terminal) = await readyModel()
    model.draft = "/mcp"
    #expect(await model.send())
    await until { model.terminalPanel != nil }
    model.terminalScreenChanged("❯ \n? for shortcuts")
    try? await Task.sleep(for: ConversationModel.panelGoneDelay * 2)
    // Not seen yet: the terminal may still be drawing it.
    #expect(model.terminalPanel != nil)
    model.terminalScreenChanged(
      "Manage MCP servers\n↑/↓ to navigate · Enter to confirm · Esc to cancel")
    model.terminalScreenChanged("❯ \n? for shortcuts")
    model.terminalScreenChanged("Manage MCP servers\nEsc to cancel")
    try? await Task.sleep(for: ConversationModel.panelGoneDelay * 2)
    #expect(model.terminalPanel != nil)
    terminal.written = []
    model.terminalScreenChanged("❯ \n? for shortcuts")
    await until { model.terminalPanel == nil }
    #expect(model.echoes.isEmpty)
    // Closed in the terminal already: nothing typed.
    #expect(terminal.written.isEmpty)
  }

  @Test("A block that never sees a panel goes by itself", .timeLimit(.minutes(1)))
  func panelNeverSeen() async {
    let (model, _) = await readyModel()
    model.draft = "/rename"
    #expect(await model.send())
    await until { model.terminalPanel != nil }
    model.terminalScreenChanged("❯ \n? for shortcuts")
    await until { model.terminalPanel == nil }
    #expect(model.echoes.isEmpty)
  }

  @Test("A session started on a command looks for its panel; one started on a message does not")
  func initialPrompt() async {
    let (model, _) = await readyModel()
    model.expectTerminalPanel(forInitialPrompt: "Refactor the parser")
    #expect(model.terminalPanel == nil)
    model.expectTerminalPanel(forInitialPrompt: "/mcp")
    #expect(model.terminalPanel == ConversationModel.TerminalPanel(echoID: nil, command: "/mcp"))

    let stopped = ConversationModel(sessionID: SessionID())
    stopped.expectTerminalPanel(forInitialPrompt: "/model")
    #expect(stopped.terminalPanel == nil)
    stopped.processRunning = { true }
    stopped.processStateChanged()
    #expect(stopped.terminalPanel?.command == "/model")
  }

  @Test("Another agent's list is not kept: a reading for the one before is dropped")
  func replaced() async {
    let (model, _) = await readyModel()
    model.draft = "/"
    let before = Gate()
    model.readCommands = {
      await before.wait()
      return AgentCommandIndex([
        AgentCommand(
          name: "stale", invocation: "/stale", description: "", kind: .skill, origin: .user)
      ])
    }
    while !(await before.isWaiting) { await Task.yield() }
    let fresh = AgentCommand(
      name: "fresh", invocation: "/fresh", description: "", kind: .skill, origin: .user)
    model.readCommands = { AgentCommandIndex([fresh]) }
    while model.commandIndex.commands != [fresh] { await Task.yield() }
    await before.open()
    while !(await before.hasReturned) { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }
    #expect(model.commandIndex.commands == [fresh])

    model.readCommands = nil
    #expect(model.commandIndex.isEmpty)
    #expect(!model.showsCommandSuggestions)
  }

  @Test("↩ completes a name begun; found by its description only, or typed in full, it does not")
  func returnCompletesOnly() async {
    let (model, _) = await readyModel()
    model.draft = "/comp"
    #expect(model.insertSelectedCommand(onReturn: true))
    #expect(model.draft == "/compact ")
    model.draft = "/context"
    #expect(model.commandSuggestions?.map(\.command.name) == ["compact"])
    #expect(!model.insertSelectedCommand(onReturn: true))
    #expect(model.draft == "/context")
    model.draft = "/compact"
    #expect(!model.insertSelectedCommand(onReturn: true))
    model.draft = "/context"
    #expect(model.insertSelectedCommand())
    #expect(model.draft == "/compact ")
  }
}

/// Holds a reading back until the test lets it go.
private actor Gate {
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var isWaiting = false
  private(set) var hasReturned = false

  func wait() async {
    isWaiting = true
    await withCheckedContinuation { waiter = $0 }
    hasReturned = true
  }

  func open() {
    waiter?.resume()
    waiter = nil
  }
}

/// The composer itself, in a window never put on screen, given the keys as the keyboard gives
/// them. Its tests belong to the suite of the history's keys: both replace the composer's text
/// view, and must not run side by side.
@MainActor private final class CommandComposer {
  let model: ConversationModel
  let terminal: Terminal
  let window: NSWindow
  let textView: NSTextView

  init(entries: [ConversationEntry] = []) async throws {
    let (model, terminal) = await readyModel(entries: entries)
    self.model = model
    self.terminal = terminal
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: VStack {
        Spacer()
        PromptComposer(model: model)
      })
    window.layoutIfNeeded()
    textView = try #require(Self.textView(in: window.contentView))
    window.makeFirstResponder(textView)
    let window = window
    PromptComposer.focusedTextView = { window.firstResponder as? NSTextView }
  }

  private static func textView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    return view as? NSTextView ?? view.subviews.lazy.compactMap(textView(in:)).first
  }

  func type(_ text: String) async {
    textView.selectAll(nil)
    textView.insertText(text, replacementRange: textView.selectedRange())
    await until { self.model.draft == text }
  }

  func press(_ key: UInt16, _ character: Int, modifiers: NSEvent.ModifierFlags = []) async {
    let characters = String(Character(UnicodeScalar(UInt32(character))!))
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)
      window.sendEvent(event!)
    }
    for _ in 0..<5 { await Task.yield() }
  }

  func down() async {
    await press(125, NSDownArrowFunctionKey, modifiers: [.numericPad, .function])
  }
  /// ↓ held: the key down, then the repeats the keyboard sends.
  func holdDown(repeats: Int) async {
    let characters = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
    for index in 0...repeats {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: index > 0, keyCode: 125)
      window.sendEvent(event!)
      for _ in 0..<5 { await Task.yield() }
    }
  }
  func up() async {
    await press(126, NSUpArrowFunctionKey, modifiers: [.numericPad, .function])
  }
  func tab() async { await press(48, 0x09) }
  func enter() async { await press(36, 0x0D) }
  func escape() async { await press(53, 0x1B) }

  func until(_ condition: @escaping () -> Bool) async {
    while !condition(), !Task.isCancelled { await Task.yield() }
  }

  func close() {
    PromptComposer.focusedTextView = { NSApp.keyWindow?.firstResponder as? NSTextView }
    window.contentView = nil
    window.close()
  }
}

extension ComposerHistoryKeysTests {
  @Test("↓ then ⇥ inserts the entry selected, the cursor after it")
  func tabInserts() async throws {
    let composer = try await CommandComposer()
    defer { composer.close() }
    await composer.type("/debug")
    await composer.down()
    #expect(composer.model.selectedCommandIndex == 1)
    await composer.tab()
    await composer.until { composer.model.draft == "/prisme-ai:debug-events " }
    await composer.until {
      composer.textView.selectedRange().location == ("/prisme-ai:debug-events " as NSString).length
    }
    #expect(composer.terminal.written.isEmpty)
  }

  @Test("↓ held down walks the list")
  func heldArrow() async throws {
    let composer = try await CommandComposer()
    defer { composer.close() }
    await composer.type("/")
    await composer.holdDown(repeats: 2)
    await composer.until { composer.model.selectedCommandIndex == 2 }
  }

  @Test("↩ inserts and sends nothing while the list is open; closed, it sends")
  func returnInserts() async throws {
    let composer = try await CommandComposer()
    defer { composer.close() }
    await composer.type("/comp")
    await composer.enter()
    await composer.until { composer.model.draft == "/compact " }
    #expect(composer.terminal.written.isEmpty)
    await composer.enter()
    await composer.until { !composer.terminal.written.isEmpty }
    #expect(composer.terminal.written.first == Array("/compact".utf8))
  }

  @Test("With nothing matching, ↩ sends the text as it is")
  func returnSendsUnknown() async throws {
    let composer = try await CommandComposer()
    defer { composer.close() }
    await composer.type("/zzz")
    #expect(composer.model.showsCommandSuggestions)
    await composer.enter()
    await composer.until { !composer.terminal.written.isEmpty }
    #expect(composer.terminal.written.first == Array("/zzz".utf8))
  }

  @Test("Escape closes the list and leaves the draft; ↑ then walks the history")
  func escapeCloses() async throws {
    let composer = try await CommandComposer(entries: [
      ConversationEntry(id: "1", content: .userPrompt("hello", attachments: 0))
    ])
    defer { composer.close() }
    await composer.type("/deb")
    await composer.up()
    #expect(composer.model.draft == "/deb")
    await composer.escape()
    await composer.until { !composer.model.showsCommandSuggestions }
    #expect(composer.model.draft == "/deb")
    await composer.up()
    await composer.until { composer.model.draft == "hello" }
  }

  @Test("↩ on `/context`, found only in `/compact`'s description, sends `/context`")
  func returnSendsDescriptionMatch() async throws {
    let composer = try await CommandComposer()
    defer { composer.close() }
    await composer.type("/context")
    #expect(composer.model.commandSuggestions?.map(\.command.name) == ["compact"])
    await composer.enter()
    await composer.until { !composer.terminal.written.isEmpty }
    #expect(composer.terminal.written.first == Array("/context".utf8))
  }

  @Test("↩ on a command typed in full sends it at once")
  func returnSendsFullName() async throws {
    let composer = try await CommandComposer()
    defer { composer.close() }
    await composer.type("/compact")
    #expect(composer.model.showsCommandSuggestions)
    await composer.enter()
    await composer.until { !composer.terminal.written.isEmpty }
    #expect(composer.terminal.written.first == Array("/compact".utf8))
  }
}
