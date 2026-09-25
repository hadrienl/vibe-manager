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

  @Test("A running terminal outranks the stored status, and says what its agent does")
  func runningWins() {
    let presentation = SessionStatusPresentation.make(
      session: session(status: .closed),
      paneStatus: .running
    )

    // Nothing is known of the agent yet: it waits.
    #expect(english(presentation.label) == "Idle")
    #expect(presentation.severity == .normal)
  }

  private func agent(
    _ activity: AgentActivity, unread: Bool = false, pane: TerminalPaneModel.Status = .running
  ) -> SessionStatusPresentation {
    SessionStatusPresentation.make(
      session: session(), paneStatus: pane,
      activity: AgentActivityState(
        activity: activity, unreadSince: unread ? Date() : nil, source: .structured))
  }

  @Test("\"Running\" is gone: each state of the agent has its words, symbol and weight")
  func agentStates() {
    let expected:
      [(SessionStatusPresentation, String, String, String, SessionStatusSeverity, Bool)] = [
        (agent(.idle), "Idle", "En attente", "moon.zzz", .normal, false),
        (agent(.working), "Working", "En cours", "arrow.triangle.2.circlepath", .active, false),
        (
          agent(.awaitingUser(.approval)), "Needs approval", "Autorisation requise",
          "hand.raised.fill", .attention, true
        ),
        (
          agent(.awaitingUser(.question)), "Has a question", "Question posée",
          "questionmark.bubble.fill", .attention, true
        ),
        (
          agent(.idle, unread: true), "New reply", "Nouvelle réponse", "text.bubble.fill",
          .attention, true
        ),
      ]
    for (presentation, english, french, symbol, severity, attention) in expected {
      #expect(Localization.string(presentation.label, in: "en") == english)
      #expect(Localization.string(presentation.label, in: "fr") == french)
      #expect(presentation.symbolName == symbol)
      #expect(presentation.severity == severity)
      #expect(presentation.needsAttention == attention)
      #expect(Localization.string(presentation.label, in: "en") != "Running")
    }
    // The three families never share a symbol: a colour nobody can tell apart still leaves them
    // apart.
    #expect(Set(expected.map(\.3)).count == expected.count)
    #expect(agent(.working).isAnimated)
    #expect(!agent(.idle).isAnimated)
  }

  @Test("A question outranks an unread answer, and work in progress hides it until it ends")
  func unreadPrecedence() {
    #expect(english(agent(.awaitingUser(.question), unread: true).label) == "Has a question")
    #expect(english(agent(.working, unread: true).label) == "Working")
  }

  @Test("The process's own states keep their place above the agent's")
  func processStatesOutrankActivity() {
    let asking = AgentActivityState(activity: .awaitingUser(.approval), source: .structured)
    let starting = SessionStatusPresentation.make(
      session: session(), paneStatus: .starting, activity: asking)
    #expect(english(starting.label) == "Starting")
    let failed = SessionStatusPresentation.make(
      session: session(), paneStatus: .exited(code: 2), activity: asking)
    #expect(failed.severity == .error)
    let stopped = SessionStatusPresentation.make(
      session: session(status: .closed), paneStatus: .exited(code: 143),
      wasStoppedOnPurpose: true, activity: asking)
    #expect(english(stopped.label) == "Closed")
    let unavailable = SessionStatusPresentation.make(
      session: session(), paneStatus: .exited(code: 0), resolution: .unknownProvider("gone"),
      activity: asking)
    #expect(english(unavailable.label) == "Agent unavailable")
  }

  @Test("VoiceOver says the agent waits for the user before saying for what")
  func accessibilityOfAttention() {
    let label = SessionStatusPresentation.accessibilityLabel(
      for: session(), status: agent(.awaitingUser(.approval)))
    #expect(label.hasSuffix("Needs attention: Needs approval"))
    let idle = SessionStatusPresentation.accessibilityLabel(for: session(), status: agent(.idle))
    #expect(idle.hasSuffix(", Idle"))
    #expect(
      Localization.string("Needs attention: \("Autorisation requise")", module: "VibeUI", in: "fr")
        == "Action requise\u{00A0}: Autorisation requise")
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
    #expect(english(running.label) == "Idle")
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

    #expect(label == "Refactor the supervisor, claude-code sonnet, Idle")
  }
}

@Suite("What the sidebar says about a session, in French")
struct SessionStatusFrenchTests {
  @Test("Every state reads in French")
  func states() {
    let expected: [(TerminalPaneModel.Status, String)] = [
      (.starting, "Démarrage"),
      (.running, "En attente"),
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
