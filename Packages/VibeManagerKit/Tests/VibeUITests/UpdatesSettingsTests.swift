import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeBrowser

@testable import VibeUI

@MainActor
final class FakeUpdater: SoftwareUpdating {
  var availability: UpdateAvailability
  var settings = UpdateSettings()
  var canCheck = true
  var lastCheck: Date?
  var waitingVersion: String?
  var readyToInstall: UpdateCandidate?
  var canOfferReadyUpdate: Bool { readyToInstall != nil }
  private(set) var offers = 0
  var onChange: (() -> Void)?
  private(set) var checks = 0

  init(availability: UpdateAvailability = .available) {
    self.availability = availability
  }

  func checkNow() {
    checks += 1
    canCheck = false
  }

  func offerReadyUpdate() {
    offers += 1
  }
}

@Suite("The Updates tab")
@MainActor
struct UpdatesSettingsTests {
  @Test("A setting changed in the tab reaches the updater, and reads back what it kept")
  func settingsReachTheUpdater() {
    let updater = FakeUpdater()
    let model = UpdatesModel(updater: updater)
    #expect(model.settings == UpdateSettings())
    #expect(model.settings.channel == .stable)
    #expect(model.settings.automaticallyChecks)
    #expect(!model.settings.automaticallyDownloads)

    model.change { $0.channel = .unstable }
    #expect(updater.settings.channel == .unstable)
    model.change { $0.interval = .weekly }
    #expect(updater.settings.interval == .weekly)
    #expect(model.settings.channel == .unstable)
  }

  @Test("Check Now asks the updater, and follows what it says of itself afterwards")
  func checkNow() {
    let updater = FakeUpdater()
    let model = UpdatesModel(updater: updater)
    model.checkNow()
    #expect(updater.checks == 1)
    #expect(!model.canCheck)

    let checked = Date(timeIntervalSince1970: 1_800_000_000)
    updater.canCheck = true
    updater.lastCheck = checked
    updater.waitingVersion = "1.1.0"
    updater.onChange?()
    #expect(model.canCheck)
    #expect(model.lastCheck == checked)
    #expect(model.waitingVersion == "1.1.0")

    // Set aside by Later: said, and offered again from the menu.
    updater.readyToInstall = UpdateCandidate(version: "1.1.0", hostProtocol: 1)
    updater.onChange?()
    #expect(model.readyToInstall?.version == "1.1.0")
    model.offerReadyUpdate()
    #expect(updater.offers == 1)
  }

  @Test("The tab is there once the application gave the workspace an updater, wide enough")
  func tabWidth() {
    _ = NSApplication.shared
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: BrowserWorkspace())
    model.updates = UpdatesModel(updater: FakeUpdater(availability: .unavailable(.isolatedCopy)))
    model.settingsTab = .updates
    let host = NSHostingView(rootView: SettingsView(model: model))
    #expect(host.fittingSize.width >= SettingsView.formWidth)
  }

  @Test("Every reason a copy does not update itself is said")
  func explanations() {
    let reasons: [UpdateAvailability.Reason] = [
      .developmentBuild, .isolatedCopy, .turnedOff, .notConfigured, .failed,
    ]
    let texts = Set(reasons.map { String(localized: UpdatesSettingsView.explanation(of: $0)) })
    #expect(texts.count == reasons.count)
  }
}
