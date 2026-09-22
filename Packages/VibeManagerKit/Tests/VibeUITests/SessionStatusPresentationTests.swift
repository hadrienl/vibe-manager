import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

@Suite("What the sidebar says about a session")
struct SessionStatusPresentationTests {
  private func session(status: SessionStatus = .active) -> WorkSession {
    WorkSession(
      name: "Refactor the supervisor",
      agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet"),
      status: status
    )
  }

  @Test("A running terminal outranks the stored status")
  func runningWins() {
    let presentation = SessionStatusPresentation.make(
      session: session(status: .closed),
      paneStatus: .running
    )

    #expect(presentation.label == "Running")
    #expect(presentation.severity == .normal)
  }

  @Test("A failure is an error, and says which one")
  func failuresAreErrors() {
    let failed = SessionStatusPresentation.make(
      session: session(),
      paneStatus: .failed(message: "No such file")
    )
    let exited = SessionStatusPresentation.make(session: session(), paneStatus: .exited(code: 127))
    let terminated = SessionStatusPresentation.make(
      session: session(),
      paneStatus: .terminated(signal: 9)
    )

    #expect(failed.severity == .error)
    #expect(exited.severity == .error)
    #expect(exited.label.contains("127"))
    #expect(terminated.severity == .error)
    #expect(terminated.label.contains("9"))
  }

  @Test("A clean exit is not a failure")
  func cleanExitIsNotAnError() {
    let presentation = SessionStatusPresentation.make(
      session: session(), paneStatus: .exited(code: 0))

    #expect(presentation.label == "Finished")
    #expect(presentation.severity == .normal)
  }

  @Test("Each state has its own symbol, so colour is never the only difference")
  func statesAreTellableApart() {
    let states: [SessionStatusPresentation] = [
      .make(session: session(status: .active), paneStatus: .running),
      .make(session: session(status: .closed), paneStatus: nil),
      .make(session: session(status: .archived), paneStatus: nil),
      .make(session: session(), paneStatus: .failed(message: "No such file")),
    ]

    #expect(Set(states.map(\.symbolName)).count == states.count)
    #expect(Set(states.map(\.label)).count == states.count)
  }

  @Test("A missing agent is reported only when nothing is running")
  func missingAgentYieldsToARunningProcess() {
    let unknown = SessionAgentResolution.unknownProvider("codex")

    let idle = SessionStatusPresentation.make(
      session: session(status: .closed),
      paneStatus: nil,
      resolution: unknown
    )
    let running = SessionStatusPresentation.make(
      session: session(),
      paneStatus: .running,
      resolution: unknown
    )

    #expect(idle.label == "Agent unavailable")
    #expect(idle.severity == .attention)
    #expect(running.label == "Running")
  }

  @Test("VoiceOver hears the name, the agent and the state")
  func accessibilityLabelCarriesTheState() {
    let session = session()
    let status = SessionStatusPresentation.make(session: session, paneStatus: .running)

    let label = SessionStatusPresentation.accessibilityLabel(for: session, status: status)

    #expect(label == "Refactor the supervisor, claude-code sonnet, Running")
  }
}
