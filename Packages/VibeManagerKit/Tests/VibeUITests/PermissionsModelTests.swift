import Foundation
import Testing
import VibeApplication

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
    // The settings window asks on its own, and the answer is recorded asynchronously: neither
    // must be able to take the step off the screen while it is being read.
    let model = makeModel(status: .notGranted, preferences: SpyPreferences())
    await model.refresh()
    #expect(model.isPresentingStep)

    await model.refresh()

    #expect(model.isPresentingStep)
  }

  @Test("The settings window asks the system again, and never reopens the step")
  func recheckReadsTheSystemAgain() async {
    let probe = MutableProbe(status: .notGranted)
    let model = PermissionsModel(
      gate: FullDiskAccessGate(probe: probe, preferences: SpyPreferences()),
      openURL: { _ in }
    )
    await model.refresh()
    await model.skipStep()
    #expect(model.status == .notGranted)

    // Granted elsewhere, in System Settings, while the application is running.
    await probe.grant()
    await model.recheck()

    #expect(model.isGranted)
    #expect(!model.isPresentingStep)
  }

  private func makeModel(
    status: FullDiskAccessStatus,
    preferences: SpyPreferences,
    opened: OpenedURLs = OpenedURLs()
  ) -> PermissionsModel {
    PermissionsModel(
      gate: FullDiskAccessGate(probe: StubProbe(status: status), preferences: preferences),
      openURL: { opened.urls.append($0) }
    )
  }
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

private actor MutableProbe: FullDiskAccessProbe {
  private var value: FullDiskAccessStatus

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func grant() { value = .granted }

  func status() async -> FullDiskAccessStatus { value }
}

private actor SpyPreferences: PermissionPreferences {
  private var dismissed = false
  private(set) var dismissals = 0

  func isFullDiskAccessStepDismissed() -> Bool { dismissed }

  func dismissFullDiskAccessStep() {
    dismissals += 1
    dismissed = true
  }
}
