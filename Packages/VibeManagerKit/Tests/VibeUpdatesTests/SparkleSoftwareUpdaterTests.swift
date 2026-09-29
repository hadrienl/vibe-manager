import Foundation
import Testing
import VibeApplication

@testable import VibeUpdates

@Suite("The Sparkle updater")
struct SparkleSoftwareUpdaterTests {
  @Test("Stable sees the default channel only; unstable sees the release candidates besides")
  func channels() {
    #expect(SparkleSoftwareUpdater.allowedChannels(for: .stable).isEmpty)
    #expect(SparkleSoftwareUpdater.allowedChannels(for: .unstable) == ["unstable"])
  }

  @Test("The host protocol is read from the feed's own element, and absent when it is not there")
  func hostProtocol() {
    #expect(
      SparkleSoftwareUpdater.candidate(
        version: "1.1.0", properties: ["vibe:hostProtocol": "2", "sparkle:version": "900"])
        == UpdateCandidate(version: "1.1.0", hostProtocol: 2))
    #expect(
      SparkleSoftwareUpdater.candidate(version: "1.1.0", properties: ["vibe:hostProtocol": " 1\n"])
        .hostProtocol == 1)
    #expect(
      SparkleSoftwareUpdater.candidate(version: "1.1.0", properties: [:]).hostProtocol == nil)
    #expect(
      SparkleSoftwareUpdater.candidate(version: "1.1.0", properties: ["vibe:hostProtocol": "two"])
        .hostProtocol == nil)
  }

  @Test("The test runner is no release: it never updates itself")
  @MainActor
  func testRunnerIsDevelopment() throws {
    let defaults = try #require(UserDefaults(suiteName: "VibeUpdatesTests.\(UUID())"))
    let updater = SparkleSoftwareUpdater(bundle: .main, environment: [:], defaults: defaults)
    #expect(updater.availability != .available)
    #expect(!updater.canCheck)
    #expect(updater.lastCheck == nil)
    // Unavailable, nothing is changed: there is no updater to hand the choice to.
    var settings = updater.settings
    #expect(settings.channel == .stable)
    settings.channel = .unstable
    updater.settings = settings
    #expect(updater.settings.channel == .stable)
  }
}
