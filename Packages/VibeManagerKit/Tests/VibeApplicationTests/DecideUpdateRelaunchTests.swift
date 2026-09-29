import Foundation
import Testing
import VibeApplication

@Suite("Relaunching for an update")
struct DecideUpdateRelaunchTests {
  private func situation(
    hosted: Int = 0,
    inProcess: Int = 0,
    behavior: QuitBehavior = .ask,
    restoring: Bool = false,
    modal: Bool = false,
    hostProtocol: Int? = 1
  ) -> UpdateRelaunchSituation {
    UpdateRelaunchSituation(
      hostedRunningCount: hosted,
      inProcessRunningCount: inProcess,
      quitBehavior: behavior,
      isRestoring: restoring,
      isPresentingModal: modal,
      currentHostProtocol: 1,
      candidate: UpdateCandidate(version: "1.1.0", hostProtocol: hostProtocol))
  }

  @Test("Nothing running: relaunch at once, nothing to ask")
  func nothingRunning() {
    #expect(
      DecideUpdateRelaunch.decide(situation(inProcess: 2))
        == .proceed(keepingAgentsRunning: false))
  }

  @Test("Agents running and the quit question not settled: asked, with the agents that stop anyway")
  func agentsRunningAsk() {
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 3, inProcess: 1))
        == .ask(.keepOrStop(running: 3, inProcess: 1)))
  }

  @Test("The answer remembered for quitting answers for an update too")
  func rememberedAnswer() {
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 2, behavior: .keepRunning))
        == .proceed(keepingAgentsRunning: true))
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 2, behavior: .stopAll))
        == .proceed(keepingAgentsRunning: false))
  }

  @Test("A restoration under way, or a sheet open, puts the relaunch off without asking")
  func waits() {
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 1, restoring: true)) == .wait(.restoring))
    #expect(DecideUpdateRelaunch.decide(situation(modal: true)) == .wait(.modal))
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 1, restoring: true, modal: true))
        == .wait(.restoring))
  }

  @Test("A version that speaks another core of the host protocol never offers to keep them running")
  func incompatibleHost() {
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 2, hostProtocol: 2))
        == .ask(.mustStop(running: 2)))
    // Remembered as "keep running": still asked, since that answer cannot be honoured.
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 2, behavior: .keepRunning, hostProtocol: 2))
        == .ask(.mustStop(running: 2)))
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 2, behavior: .stopAll, hostProtocol: 2))
        == .proceed(keepingAgentsRunning: false))
    // Nothing running: nothing to lose.
    #expect(
      DecideUpdateRelaunch.decide(situation(hostProtocol: 2))
        == .proceed(keepingAgentsRunning: false))
  }

  @Test("A feed that does not name the protocol is the protocol of every version so far")
  func unnamedProtocol() {
    #expect(
      DecideUpdateRelaunch.decide(situation(hosted: 1, behavior: .keepRunning, hostProtocol: nil))
        == .proceed(keepingAgentsRunning: true))
  }
}

@Suite("Whether a copy updates itself")
struct UpdateAvailabilityTests {
  @Test("Only a Developer ID build with its key, in its own data, updates itself")
  func availability() {
    #expect(
      UpdateAvailability.evaluate(
        environment: [:], isSignedWithDeveloperID: true, hasPublicKey: true) == .available)
    #expect(
      UpdateAvailability.evaluate(
        environment: [:], isSignedWithDeveloperID: false, hasPublicKey: true)
        == .unavailable(.developmentBuild))
    #expect(
      UpdateAvailability.evaluate(
        environment: [:], isSignedWithDeveloperID: true, hasPublicKey: false)
        == .unavailable(.notConfigured))
    #expect(
      UpdateAvailability.evaluate(
        environment: ["VIBE_DATA_DIRECTORY": "/tmp/copy"], isSignedWithDeveloperID: true,
        hasPublicKey: true) == .unavailable(.isolatedCopy))
    #expect(
      UpdateAvailability.evaluate(
        environment: ["VIBE_UPDATES": "off"], isSignedWithDeveloperID: true, hasPublicKey: true)
        == .unavailable(.turnedOff))
    // A copy made to test an update says so; it still has to be a release build.
    #expect(
      UpdateAvailability.evaluate(
        environment: ["VIBE_DATA_DIRECTORY": "/tmp/copy", "VIBE_UPDATES": "on"],
        isSignedWithDeveloperID: true, hasPublicKey: true) == .available)
    #expect(
      UpdateAvailability.evaluate(
        environment: ["VIBE_DATA_DIRECTORY": "/tmp/copy", "VIBE_UPDATES": "on"],
        isSignedWithDeveloperID: false, hasPublicKey: true) == .unavailable(.developmentBuild))
    // An empty variable is no data directory.
    #expect(
      UpdateAvailability.evaluate(
        environment: ["VIBE_DATA_DIRECTORY": ""], isSignedWithDeveloperID: true,
        hasPublicKey: true) == .available)
  }

  @Test("An interval set by hand is read as the closest of the three")
  func interval() {
    #expect(UpdateCheckInterval(seconds: 86_400) == .daily)
    #expect(UpdateCheckInterval(seconds: 3_600) == .daily)
    #expect(UpdateCheckInterval(seconds: 500_000) == .weekly)
    #expect(UpdateCheckInterval(seconds: 10_000_000) == .monthly)
  }
}
