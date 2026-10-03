import Foundation
import Testing
import VibeDomain
import WebKit

@testable import VibeBrowser

/// A page gets the microphone only once the user said so: through WebKit's question for a page of
/// the user's, through the question of the agent's effects for one the agent drives; never the
/// camera (#315).
@Suite("The microphone of a page")
@MainActor
struct BrowserMediaCaptureTests {
  @Test("The decision: WebKit asks the user's page, the session asks the agent's, no camera")
  func decision() {
    #expect(
      BrowserMediaCapture.decide(.microphone, asksBeforeEffects: false, isOnScreen: true)
        == .prompt)
    #expect(
      BrowserMediaCapture.decide(.microphone, asksBeforeEffects: true, isOnScreen: true)
        == .askUser)
    #expect(
      BrowserMediaCapture.decide(.microphone, asksBeforeEffects: true, isOnScreen: false)
        == .askUser)
    #expect(
      BrowserMediaCapture.decide(.microphone, asksBeforeEffects: false, isOnScreen: false)
        == .deny(reason: "Microphone refused: the tab is not shown."))
    for type in [WKMediaCaptureType.camera, .cameraAndMicrophone] {
      for agent in [false, true] {
        guard
          case .deny = BrowserMediaCapture.decide(type, asksBeforeEffects: agent, isOnScreen: true)
        else {
          Issue.record("\(type.rawValue) not refused")
          continue
        }
      }
    }
  }

  @Test("The user's page on screen is left to WebKit's question, the camera refused")
  func usersPage() async {
    let workspace = BrowserWorkspace()
    let tab = workspace.open(
      URL(string: "https://example.com")!, in: SessionID(), openedBy: .user, activate: false)
    #expect(await tab.decideMediaCapture(.microphone, isOnScreen: true) == .prompt)
    #expect(await tab.decideMediaCapture(.microphone, isOnScreen: false) == .deny)
    #expect(await tab.decideMediaCapture(.cameraAndMicrophone, isOnScreen: true) == .deny)
    #expect(workspace.pendingRequests.isEmpty)
    #expect(tab.console.entries.contains { $0.text.hasPrefix("Camera refused") })
  }

  @Test("The agent's page is asked in the session: a yes grants it, a no refuses it")
  func agentsPage() async throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(
      URL(string: "https://example.com")!, in: session, openedBy: .agent, activate: false)

    for (answer, expected) in [
      (BrowserPermissionAnswer.allowOnce, WKPermissionDecision.grant), (.deny, .deny),
    ] {
      let decision = Task { await tab.decideMediaCapture(.microphone, isOnScreen: false) }
      await waitUntil("the microphone is asked") {
        workspace.requests(for: session).contains { $0.kind == .effect(.microphone) }
      }
      workspace.answer(try #require(workspace.requests(for: session).first), with: answer)
      #expect(await decision.value == expected)
    }
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("A window the agent's page opened is asked, even once the user clicked in it")
  func windowOfTheAgentsPage() async throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let opener = workspace.open(
      URL(string: "https://example.com")!, in: session, openedBy: .agent, activate: false)
    let window = workspace.open(
      URL(string: "https://example.com/window")!, in: session, openedBy: .agent,
      activate: false, from: opener.id)
    window.userDidInteract()

    let decision = Task { await window.decideMediaCapture(.microphone, isOnScreen: true) }
    await waitUntil("the microphone is asked") { !workspace.requests(for: session).isEmpty }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .deny)
    #expect(await decision.value == .deny)
  }

  @Test("A page the user took back is left to WebKit's question")
  func takenBack() async {
    let workspace = BrowserWorkspace()
    let tab = workspace.open(
      URL(string: "https://example.com")!, in: SessionID(), openedBy: .agent, activate: false)
    tab.userDidInteract()
    #expect(await tab.decideMediaCapture(.microphone, isOnScreen: true) == .prompt)
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("A closed tab, or one nobody can ask for, is refused")
  func nobodyToAsk() async {
    let tab = BrowserTabModel(
      url: URL(string: "https://example.com")!, openedBy: .agent,
      configuration: BrowserWebConfiguration(storeIdentifierFile: nil))
    #expect(await tab.decideMediaCapture(.microphone, isOnScreen: true) == .deny)
    tab.confirmAgentEffect = { _, _ in true }
    tab.isClosed = true
    #expect(await tab.decideMediaCapture(.microphone, isOnScreen: true) == .deny)
  }
}
