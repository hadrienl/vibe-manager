import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The one-time file access step")
struct PermissionsModelTests {
  @Test("With the access granted, the step never appears")
  func grantedShowsNothing() async {
    let model = makeModel(status: .granted, preferences: SpyPreferences())

    await model.refresh()

    #expect(model.isGranted)
    #expect(!model.isPresentingStep)
  }

  @Test("Without it, the step is presented once")
  func notGrantedShowsTheStep() async {
    let model = makeModel(status: .notGranted, preferences: SpyPreferences())

    await model.refresh()

    #expect(model.status == .notGranted)
    #expect(model.isPresentingStep)
  }

  @Test("Skipping closes it, and the next launch does not ask again")
  func skippingIsFinal() async {
    let preferences = SpyPreferences()
    let model = makeModel(status: .notGranted, preferences: preferences)
    await model.refresh()

    await model.skipStep()
    #expect(!model.isPresentingStep)

    // A launch of its own, over the preferences the first one wrote.
    let next = makeModel(status: .notGranted, preferences: preferences)
    await next.refresh()

    #expect(!next.isPresentingStep)
    #expect(next.status == .notGranted)
  }

  @Test("Opening System Settings opens the Full Disk Access pane, and closes the step")
  func openingSettingsGoesToTheRightPane() async {
    let opened = OpenedURLs()
    let preferences = SpyPreferences()
    let model = makeModel(status: .notGranted, preferences: preferences, opened: opened)
    await model.refresh()

    await model.answerStepByOpeningSystemSettings()

    #expect(opened.urls == [PermissionsModel.fullDiskAccessSettingsURL])
    #expect(opened.urls.first?.absoluteString.contains("Privacy_AllFiles") == true)
    #expect(!model.isPresentingStep)
    // The step is answered even though the switch itself is flipped elsewhere: coming back to a
    // question the user has already gone to answer would be asking twice.
    #expect(await preferences.dismissals == 1)
  }

  @Test("The settings window opens the same pane without answering the step")
  func settingsWindowDoesNotAnswerTheStep() async {
    // The button in the settings window is reachable before the step has ever been shown. Clicking
    // it and then changing one's mind must not silence a question that was never asked.
    let opened = OpenedURLs()
    let preferences = SpyPreferences()
    let model = makeModel(status: .notGranted, preferences: preferences, opened: opened)

    model.openSystemSettings()

    #expect(opened.urls == [PermissionsModel.fullDiskAccessSettingsURL])
    #expect(await preferences.dismissals == 0)

    // The next launch still has the step to show.
    let next = makeModel(status: .notGranted, preferences: preferences)
    await next.refresh()

    #expect(next.isPresentingStep)
  }

  @Test("Asking the question again never closes a step the user is reading")
  func refreshDoesNotCloseAnOpenStep() async {
    let model = makeModel(status: .notGranted, preferences: SpyPreferences())
    await model.refresh()
    #expect(model.isPresentingStep)

    await model.refresh()

    #expect(model.isPresentingStep)
  }

  @Test("Back from System Settings, a process born now is asked, and sees the grant")
  func comingBackAsksAProcessBornNow() async {
    // This window cannot see it: TCC settled its access when it started (#76).
    let current = MutableCurrentProbe()
    let model = PermissionsModel(
      gate: FullDiskAccessGate(
        probe: StubProbe(status: .notGranted), preferences: SpyPreferences(), current: current),
      openURL: { _ in })
    await model.refresh()
    await model.skipStep()

    await model.applicationDidBecomeActive()
    #expect(await current.probes == 0)

    model.openSystemSettings()
    await current.grant()
    await model.applicationDidBecomeActive()

    #expect(model.isGranted)
    #expect(model.situation == .granted)
    #expect(!model.isPresentingStep)
  }

  @Test("Past a while after the trip to System Settings, coming back asks no process any more")
  func comingBackLaterAsksNothing() async {
    let current = MutableCurrentProbe()
    let clock = MutableDate()
    let model = PermissionsModel(
      gate: FullDiskAccessGate(
        probe: StubProbe(status: .notGranted), preferences: SpyPreferences(), current: current),
      openURL: { _ in }, now: { clock.value })
    model.openSystemSettings()

    await model.applicationDidBecomeActive()
    #expect(await current.probes == 1)

    clock.value = clock.value.addingTimeInterval(PermissionsModel.grantWatchDuration + 1)
    await model.applicationDidBecomeActive()
    await model.applicationDidBecomeActive()

    #expect(await current.probes == 1)
  }

  @Test("An idle host born before the grant is restarted without a word")
  func idleHostIsRestartedSilently() async {
    let runner = SpyRunner(hostStatus: .notGranted, running: [])
    let model = makeModel(status: .granted, preferences: SpyPreferences(), runner: runner)

    await model.reevaluate(refreshingIdentity: false)

    #expect(await runner.restartRequests == 1)
    #expect(model.situation == .granted)
    #expect(!model.showsRestartNotice)
  }

  @Test("A busy host born before the grant is only talked about, never stopped")
  func busyHostIsOnlyTalkedAbout() async {
    let runner = SpyRunner(hostStatus: .notGranted, running: [SessionID(), SessionID()])
    let model = makeModel(status: .granted, preferences: SpyPreferences(), runner: runner)

    await model.reevaluate(refreshingIdentity: false)

    #expect(model.situation == .pendingRestart(runner: .host, runningAgents: 2))
    #expect(model.showsRestartNotice)
    #expect(model.agentAccess == .notGranted)
    #expect(await runner.restartRequests == 0)

    await model.restartWhenIdle()

    #expect(model.isRestartArmed)
    #expect(await runner.restartRequests == 1)
    #expect(await runner.stoppedAnything == false)
  }

  @Test("A closed notice stays closed for the same lag")
  func dismissedNoticeStaysClosed() async {
    let runner = SpyRunner(hostStatus: .notGranted, running: [SessionID(), SessionID()])
    let model = makeModel(status: .granted, preferences: SpyPreferences(), runner: runner)
    await model.reevaluate(refreshingIdentity: false)

    model.dismissRestartNotice()
    await model.reevaluate(refreshingIdentity: false)
    #expect(!model.showsRestartNotice)

    // One agent fewer is still the same lag.
    await runner.finishOne()
    await model.reevaluate(refreshingIdentity: false)
    #expect(model.situation == .pendingRestart(runner: .host, runningAgents: 1))
    #expect(!model.showsRestartNotice)
  }

  private func makeModel(
    status: FullDiskAccessStatus,
    preferences: SpyPreferences,
    opened: OpenedURLs = OpenedURLs(),
    runner: SpyRunner? = nil
  ) -> PermissionsModel {
    PermissionsModel(
      gate: FullDiskAccessGate(
        probe: StubProbe(status: status), preferences: preferences, runner: runner),
      control: runner,
      openURL: { opened.urls.append($0) }
    )
  }
}

@MainActor
private final class MutableDate {
  var value = Date(timeIntervalSince1970: 1_790_000_000)
}

@MainActor
private final class OpenedURLs {
  var urls: [URL] = []
}

private struct StubProbe: FullDiskAccessProbe {
  let value: FullDiskAccessStatus

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func status() async -> FullDiskAccessStatus { value }
}

private actor MutableCurrentProbe: CurrentFullDiskAccessProbe {
  private var value: FullDiskAccessStatus = .notGranted
  private(set) var probes = 0

  func grant() { value = .granted }

  func status() async -> FullDiskAccessStatus? {
    probes += 1
    return value
  }
}

private actor SpyPreferences: PermissionPreferences {
  func isFullDiskAccessStepSuppressed() -> Bool { false }

  private var answer: CodeIdentityFingerprint?
  private(set) var dismissals = 0

  func fullDiskAccessStepAnswer() -> CodeIdentityFingerprint? { answer }

  func recordFullDiskAccessStepAnswer(by identity: CodeIdentityFingerprint) {
    dismissals += 1
    answer = identity
  }
}

/// A host that lags behind the grant, and that restarts — goes away — only when idle.
private actor SpyRunner: AgentRunnerControl {
  private var hostStatus: FullDiskAccessStatus?
  private var running: [SessionID]
  private var isGone = false
  private var armed = false
  private(set) var restartRequests = 0
  private(set) var stoppedAnything = false

  init(hostStatus: FullDiskAccessStatus?, running: [SessionID]) {
    self.hostStatus = hostStatus
    self.running = running
  }

  func agentRunnerAccess() -> AgentRunnerAccess {
    isGone
      ? .none
      : AgentRunnerAccess(runner: .host, hostStatus: hostStatus, runningAgents: running.count)
  }

  func runningHostedSessions() -> [SessionID] { running }

  func restartHostWhenIdle() -> HostRestart {
    restartRequests += 1
    guard running.isEmpty else {
      armed = true
      return .armed
    }
    isGone = true
    return .restarted
  }

  func cancelHostRestart() { armed = false }

  func finishOne() { running.removeLast() }

  func isHostRestartArmed() -> Bool { armed }
}
