import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("The composer's shell mode (#188)")
struct ShellModeTests {
  private final class Terminal: @unchecked Sendable {
    var written: [[UInt8]] = []
  }

  private func model(shell: ShellEntry? = ShellEntry(switchDelay: .zero, chunkDelay: .zero))
    -> (ConversationModel, Terminal)
  {
    let model = ConversationModel(sessionID: SessionID())
    let terminal = Terminal()
    model.write = { terminal.written.append($0) }
    model.processRunning = { true }
    model.promptFormat = AgentPromptFormat(
      queueKey: [0x09], submitDelay: .zero, shellEntry: shell)
    model.apply(ConversationSnapshot(availability: .available))
    return (model, terminal)
  }

  private func shellEntry(_ id: String, _ command: String) -> ConversationEntry {
    ConversationEntry(id: id, content: .notice(.shell(ShellRun(command: command))))
  }

  @Test("The mode is read from the draft: a `!` first, for an agent that has a shell mode")
  func mode() {
    let (model, _) = model()
    #expect(model.composerMode == .message)
    model.draft = "!"
    #expect(model.composerMode == .shell)
    model.draft = "\\!ls"
    #expect(model.composerMode == .message)
    model.draft = " !ls"
    #expect(model.composerMode == .message)
    let (plain, _) = self.model(shell: nil)
    plain.draft = "!ls"
    #expect(plain.composerMode == .message)
    #expect(plain.opensOnBangWithoutShellMode)
    // Only a composer that sends prompts has a shell mode: an answer opening on `!` is an answer.
    model.processRunning = { false }
    model.draft = "!ls"
    #expect(model.composerMode == .message)
  }

  @Test("A command goes through the shell mode, never as a message, and its echo is a command")
  func send() async {
    let (model, terminal) = model()
    model.draft = "!git status"
    #expect(await model.send())
    #expect(terminal.written == [Array("!".utf8), Array("git status".utf8), [0x0D]])
    #expect(model.echoes.map(\.kind) == [.shell(command: "git status")])
    #expect(model.echoes.map(\.text) == ["git status"])
    // A prompt written meanwhile is not the command.
    model.apply(
      ConversationSnapshot(
        entries: [ConversationEntry(id: "u", content: .userPrompt("hi", attachments: []))],
        availability: .available))
    #expect(model.echoes.count == 1)
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "u", content: .userPrompt("hi", attachments: [])),
          shellEntry("s", "git status"),
        ], availability: .available))
    #expect(model.echoes.isEmpty)
  }

  @Test("A message opening on `!` is sent with `\\!`, as a message")
  func literal() async {
    let (model, terminal) = model()
    model.draft = "\\!important"
    #expect(await model.send())
    #expect(terminal.written.first == Array("\u{1B}[200~!important\u{1B}[201~".utf8))
    #expect(model.echoes.map(\.text) == ["!important"])
    #expect(model.echoes.map(\.kind) == [.message])
    #expect(model.promptHistory.prompts == ["\\!important"])
  }

  @Test("A command is held back empty, with files joined, or while the agent works")
  func held() {
    let (model, _) = model()
    model.draft = "!"
    #expect(model.shellHold == .empty)
    #expect(!model.canSend)
    model.draft = "!ls"
    #expect(model.canSend)
    model.activity = .working
    #expect(model.shellHold == .working)
    #expect(!model.canSend)
    model.promptFormat.shellEntry?.queuesWhileWorking = true
    #expect(model.canSend)
    model.activity = nil
    model.draft = "look"
    model.attach([URL(fileURLWithPath: "/tmp/a.png")])
    model.draft = "!ls"
    #expect(model.shellHold == .attachments)
    #expect(!model.canSend)
  }

  @Test("In shell mode, a file joined is named in the command, escaped")
  func attach() {
    let (model, _) = model()
    model.draft = "!open"
    model.attach([URL(fileURLWithPath: "/Users/a/My Shot.png")])
    #expect(model.draft == #"!open /Users/a/My\ Shot.png"#)
    #expect(model.attachments.isEmpty)
  }

  @Test("Escape leaves the shell mode and keeps the text, after putting back a recalled draft")
  func escape() {
    let (model, _) = model()
    model.apply(
      ConversationSnapshot(entries: [shellEntry("s", "make")], availability: .available))
    model.draft = "!ls"
    #expect(model.recallOlderPrompt())
    #expect(model.draft == "!make")
    #expect(model.composerMode == .shell)
    #expect(model.cancelPromptRecall())
    #expect(model.draft == "!ls")
    #expect(model.leaveShellMode())
    #expect(model.draft == "ls")
    #expect(!model.leaveShellMode())
  }

  @Test("A command never run — put back in the agent's prompt — holds back no other")
  func strandedCommand() async {
    let (model, _) = model()
    model.draft = "!make"
    await model.send()
    model.draft = "!ls"
    await model.send()
    model.apply(
      ConversationSnapshot(entries: [shellEntry("s", "ls")], availability: .available))
    #expect(model.echoes.map(\.text) == ["make"])
    // An older run of the same command confirms nothing sent after it.
    model.apply(
      ConversationSnapshot(
        entries: [shellEntry("s", "ls"), shellEntry("t", "make")], availability: .available))
    #expect(model.echoes.isEmpty)
  }

  @Test("Edit Again puts the draft aside, as ↑ would: Escape gives it back")
  func editAgain() {
    let (model, _) = model()
    let run = ShellRun(command: "make", state: .succeeded)
    model.apply(
      ConversationSnapshot(
        entries: [ConversationEntry(id: "s", content: .notice(.shell(run)))],
        availability: .available))
    model.draft = "a long message"
    model.editAgain(run)
    #expect(model.draft == "!make")
    #expect(model.cancelPromptRecall())
    #expect(model.draft == "a long message")
  }

  @Test("A command queued during a turn is not taken for lost while the turn goes on")
  func queued() async {
    var shell = ShellEntry(switchDelay: .zero, chunkDelay: .zero)
    shell.queuesWhileWorking = true
    let (model, terminal) = model(shell: shell)
    model.activity = .working
    model.draft = "!ls"
    #expect(await model.send())
    #expect(terminal.written.last == [0x09])
    #expect(model.echoes.first?.waitsForEnd == true)
  }

  @Test("A command its agent writes once ended is not taken for lost while it runs")
  func waitsForEnd() async {
    let (model, _) = model(shell: ShellEntry(switchDelay: .zero, isRecordedAtStart: false))
    model.draft = "!sleep 60"
    await model.send()
    #expect(model.echoes.first?.waitsForEnd == true)
    #expect(model.promptHistory.prompts == ["!sleep 60"])
  }
}
