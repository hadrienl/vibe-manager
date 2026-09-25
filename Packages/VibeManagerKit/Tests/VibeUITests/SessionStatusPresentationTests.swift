import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting
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

    #expect(english(presentation.label) == "Running")
    #expect(presentation.severity == .normal)
  }

  @Test("A session the user closed reads as closed, not as the signal that stopped its agent")
  func deliberateStopIsNotAFailure() {
    // Close and Archive kill the agent, and it reports the signal it was killed with — 143 for
    // SIGTERM. Shown as an exit code it is a red alarm about something the user just did.
    let closed = SessionStatusPresentation.make(
      session: session(status: .closed),
      paneStatus: .exited(code: 143),
      wasStoppedOnPurpose: true
    )

    #expect(english(closed.label) == "Closed")
    #expect(closed.severity == .normal)

    // The same code, from an agent nobody asked to stop, is still a failure.
    let crashed = SessionStatusPresentation.make(
      session: session(status: .closed),
      paneStatus: .exited(code: 143)
    )

    #expect(crashed.severity == .error)
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
    #expect(english(exited.label).contains("127"))
    #expect(terminated.severity == .error)
    #expect(english(terminated.label).contains("9"))
  }

  @Test("A clean exit is not a failure")
  func cleanExitIsNotAnError() {
    let presentation = SessionStatusPresentation.make(
      session: session(), paneStatus: .exited(code: 0))

    #expect(english(presentation.label) == "Finished")
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
    #expect(Set(states.map { english($0.label) }).count == states.count)
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

    #expect(english(idle.label) == "Agent unavailable")
    #expect(idle.severity == .attention)
    #expect(english(running.label) == "Running")
  }

  @Test("A terminal that simply finished does not hide a missing agent")
  func missingAgentOutranksAFinishedTerminal() {
    let unknown = SessionAgentResolution.unknownProvider("codex")

    let finished = SessionStatusPresentation.make(
      session: session(),
      paneStatus: .exited(code: 0),
      resolution: unknown
    )
    // A terminal that ended badly still says more: that is what just happened here.
    let failed = SessionStatusPresentation.make(
      session: session(),
      paneStatus: .exited(code: 127),
      resolution: unknown
    )

    #expect(english(finished.label) == "Agent unavailable")
    #expect(english(failed.label).contains("127"))
  }

  @Test("VoiceOver hears the name, the agent and the state")
  func accessibilityLabelCarriesTheState() {
    let session = session()
    let status = SessionStatusPresentation.make(session: session, paneStatus: .running)

    let label = SessionStatusPresentation.accessibilityLabel(for: session, status: status)

    #expect(label == "Refactor the supervisor, claude-code sonnet, Running")
  }
}

@Suite("What the sidebar says about a session, in French")
struct SessionStatusFrenchTests {
  @Test("Every state reads in French")
  func states() {
    let expected: [(TerminalPaneModel.Status, String)] = [
      (.starting, "Démarrage"),
      (.running, "En cours"),
      (.exited(code: 0), "Terminée"),
      (.exited(code: 127), "Terminée avec le code 127"),
      (.terminated(signal: 9), "Interrompue par le signal 9"),
      (.failed(message: "x"), "Échec"),
    ]
    for (pane, french) in expected {
      let status = SessionStatusPresentation.make(
        session: WorkSession(name: "S", status: .active), paneStatus: pane)
      #expect(Localization.string(status.label, in: "fr") == french)
    }
  }

  @Test("A session with nothing running reads its stored state in French")
  func storedStates() {
    let labels = [SessionStatus.active, .closed, .archived].map {
      Localization.string(
        SessionStatusPresentation.make(session: WorkSession(name: "S", status: $0), paneStatus: nil)
          .label,
        in: "fr")
    }
    #expect(labels == ["Arrêtée", "Fermée", "Archivée"])
  }
}

private func english(_ label: LocalizedStringResource) -> String {
  Localization.string(label, in: "en")
}
