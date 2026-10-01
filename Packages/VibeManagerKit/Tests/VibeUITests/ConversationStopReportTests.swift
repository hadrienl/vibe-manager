import Foundation
import Testing
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

@MainActor
@Suite("What a conversation says of an agent no longer running (#235)")
struct ConversationStopReportTests {
  @Test("An error is an exit status other than 0, a signal or a failure, never a stop asked for")
  func endedOnError() {
    #expect(!ConversationStopReport.endedOnError(.exited(code: 0), wasStoppedOnPurpose: false))
    #expect(ConversationStopReport.endedOnError(.exited(code: 1), wasStoppedOnPurpose: false))
    #expect(ConversationStopReport.endedOnError(.terminated(signal: 9), wasStoppedOnPurpose: false))
    #expect(ConversationStopReport.endedOnError(.failed(message: "x"), wasStoppedOnPurpose: false))
    #expect(!ConversationStopReport.endedOnError(.terminated(signal: 15), wasStoppedOnPurpose: true))
    #expect(!ConversationStopReport.endedOnError(.exited(code: 143), wasStoppedOnPurpose: true))
    #expect(!ConversationStopReport.endedOnError(.running, wasStoppedOnPurpose: false))
  }

  @Test("An agent that could not be launched says why at the foot of its conversation")
  func launchFailureShown() async {
    let pane = TerminalPaneModel(
      terminalID: SessionID().agentTerminal,
      supervisor: RefusingSupervisor(),
      spec: TerminalSpec(
        executableURL: URL(fileURLWithPath: "/bin/nope"),
        workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)),
      viewportTimeout: .zero)
    await pane.start()
    let failure = try? #require(pane.failure)

    let conversation = ConversationModel(sessionID: SessionID())
    conversation.processRunning = { false }
    conversation.launchFailure = { ConversationStopReport.launchFailure(of: pane) }

    #expect(conversation.shownLaunchFailure?.message == failure?.message)
    #expect(conversation.shownLaunchFailure?.message.contains("/bin/nope") == true)
    #expect(conversation.shownLaunchFailure?.suggestion == failure?.suggestion)
    #expect(ConversationStopReport.launchFailure(of: nil) == nil)
  }
}

private actor RefusingSupervisor: TerminalSupervisor {
  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    throw TerminalError.executableNotFound(path: "/bin/nope")
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { nil }

  func stop(id: TerminalID, gracePeriod: Duration) {}

  func stopAll(gracePeriod: Duration) {}
}
