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

    await model.openSystemSettings()

    #expect(opened.urls == [PermissionsModel.fullDiskAccessSettingsURL])
    #expect(opened.urls.first?.absoluteString.contains("Privacy_AllFiles") == true)
    #expect(!model.isPresentingStep)
    // The step is answered even though the switch itself is flipped elsewhere: coming back to a
    // question the user has already gone to answer would be asking twice.
    #expect(await preferences.dismissals == 1)
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

private actor SpyPreferences: PermissionPreferences {
  private var dismissed = false
  private(set) var dismissals = 0

  func isFullDiskAccessStepDismissed() -> Bool { dismissed }

  func dismissFullDiskAccessStep() {
    dismissals += 1
    dismissed = true
  }
}
