import CompanionCore
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeComposition

/// What the phone is shown of a request and what its answers give (#428), offline: the server's
/// pure conversions, without a phone or a session.
@Suite("The phone's requests")
struct CompanionRemoteRequestTests {
  let questions = [
    AgentQuestion(
      header: "Action", text: "What now?",
      options: [.init(label: "Merge", description: "Squash"), .init(label: "Wait")],
      allowsFreeText: false),
    AgentQuestion(
      header: "Checks", text: "Which checks?",
      options: [.init(label: "Tests"), .init(label: "Lint"), .init(label: "Build")],
      allowsMultipleChoices: true),
  ]

  @Test("Every question goes to the phone, its first also as protocol 1 says it")
  @MainActor
  func shown() throws {
    let request = AgentRequest(
      id: AgentRequestID(sessionID: SessionID(rawValue: UUID()), key: "K"), receivedAt: Date(),
      kind: .question, content: .questions(questions), reference: AgentToolReference(tool: nil),
      isShown: true)
    let remote = try #require(CompanionRemoteServer.request(of: request))
    #expect(remote.id == "K")
    #expect(remote.kind == .question)
    #expect(remote.questions.map(\.header) == ["Action", "Checks"])
    #expect(remote.questions.map(\.allowsSeveral) == [false, true])
    #expect(remote.questions[0].choices[0] == RemoteChoice(id: "0", label: "Merge", detail: "Squash"))
    #expect(remote.questions[1].allowsText)
    #expect(remote.title == "What now?")
    #expect(remote.choices.count == 2)
  }

  @Test("Two answers give both, as the Mac's panel sends them")
  @MainActor
  func twoAnswers() {
    let answer = CompanionRemoteServer.answer(
      to: .questions(questions),
      with: [RemoteAnswer(choiceIDs: ["1"]), RemoteAnswer(choiceIDs: ["0", "2"])])
    #expect(answer == .answers([.option(1), .options([0, 2])]))
    // Choices win over stray words, a blank as much as a sentence: the keymap takes no words on
    // a question of several choices.
    let stray = CompanionRemoteServer.answer(
      to: .questions(questions),
      with: [
        RemoteAnswer(choiceIDs: ["0"], text: " "),
        RemoteAnswer(choiceIDs: ["1"], text: "also lint"),
      ])
    #expect(stray == .answers([.option(0), .options([1])]))
    let words = CompanionRemoteServer.answer(
      to: .questions(questions),
      with: [RemoteAnswer(choiceIDs: [], text: "Rebase"), RemoteAnswer(choiceIDs: ["2"])])
    #expect(words == .answers([.text("Rebase"), .options([2])]))
    // Words alone on a question of several choices would not reach its dialog.
    #expect(
      CompanionRemoteServer.answer(
        to: .questions(questions),
        with: [RemoteAnswer(choiceIDs: ["0"]), RemoteAnswer(choiceIDs: [], text: "Only lint")])
        == nil)
  }

  @Test("Half an answer gives nothing: a phone of protocol 1, a question left out")
  @MainActor
  func partial() {
    let content = AgentRequestContent.questions(questions)
    #expect(CompanionRemoteServer.answer(to: content, with: [RemoteAnswer(choiceIDs: ["0"])]) == nil)
    #expect(
      CompanionRemoteServer.answer(
        to: content, with: [RemoteAnswer(choiceIDs: ["0"]), RemoteAnswer(choiceIDs: [])]) == nil)
    #expect(
      CompanionRemoteServer.answer(
        to: content, with: [RemoteAnswer(choiceIDs: ["0"]), RemoteAnswer(choiceIDs: ["9"])])
        == nil)
  }

  @Test("A single question and a permission answer as before")
  @MainActor
  func single() {
    let one = AgentRequestContent.questions([questions[0]])
    #expect(
      CompanionRemoteServer.answer(to: one, with: [RemoteAnswer(choiceIDs: ["1"])])
        == .answers([.option(1)]))
    // A notification's Allow never answers a question.
    #expect(
      CompanionRemoteServer.answer(to: one, with: [RemoteAnswer(choiceIDs: ["allowOnce"])]) == nil)
    let permission = AgentRequestContent.permission(
      AgentToolPermission(tool: .shell, toolName: "Bash", subject: "ls"))
    #expect(
      CompanionRemoteServer.answer(to: permission, with: [RemoteAnswer(choiceIDs: ["deny"])])
        == .deny)
    #expect(
      CompanionRemoteServer.answer(to: permission, with: [RemoteAnswer(choiceIDs: ["allowAlways"])])
        == .allowAlways)
  }
}

/// What the phone may create on the Mac (#469): one visible name in the folder it shows.
@MainActor
@Suite("The phone's new folders")
struct CompanionRemoteFolderTests {
  private func withParent(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let parent = root.appendingPathComponent("parent", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
      try? FileManager.default.removeItem(at: root)
    }
    try body(parent)
  }

  @Test("A name creates its folder, which the listing then shows")
  func created() throws {
    try withParent { parent in
      #expect(CompanionRemoteServer.createFolder(named: "  Nouveau été ", in: parent.path) == nil)
      #expect(CompanionRemoteServer.listing(of: parent.path).folders == ["Nouveau été"])
      // Joiners are part of a name, in an emoji or in Hindi.
      #expect(CompanionRemoteServer.createFolder(named: "👨‍💻 Projets", in: parent.path) == nil)
      #expect(CompanionRemoteServer.isFolderName("क्\u{200D}ष"))
    }
  }

  @Test(
    "A name can't leave the folder, hide, or be no name",
    arguments: [
      "", "   ", ".", "..", "../evil", "a/b", "/tmp/evil", "..%2F", ".hidden", "a:b", "a\nb",
      String(repeating: "é", count: 128),
    ])
  func refused(name: String) throws {
    // "..%2F" starts with a dot, so hidden, and refused as such: never decoded.
    try withParent { parent in
      #expect(CompanionRemoteServer.createFolder(named: name, in: parent.path) == .folderNameInvalid)
      let around = try FileManager.default.contentsOfDirectory(
        atPath: parent.deletingLastPathComponent().path)
      #expect(around == ["parent"])
      #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
  }

  @Test("What the Mac refuses is told apart")
  func failures() throws {
    try withParent { parent in
      #expect(CompanionRemoteServer.createFolder(named: "a", in: parent.path) == nil)
      #expect(CompanionRemoteServer.createFolder(named: "a", in: parent.path) == .folderExists)
      let gone = parent.appendingPathComponent("gone").path
      #expect(CompanionRemoteServer.createFolder(named: "b", in: gone) == .folderMissing)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: parent.path)
      #expect(CompanionRemoteServer.createFolder(named: "c", in: parent.path) == .folderNotAllowed)
    }
  }
}
