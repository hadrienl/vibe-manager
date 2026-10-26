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
    let words = CompanionRemoteServer.answer(
      to: .questions(questions),
      with: [RemoteAnswer(choiceIDs: ["0"]), RemoteAnswer(choiceIDs: [], text: "Only lint")])
    #expect(words == .answers([.option(0), .text("Only lint")]))
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
