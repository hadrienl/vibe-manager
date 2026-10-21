import Foundation
import Testing

@testable import VibeUI

@MainActor
@Suite("The iPhone companion's settings")
struct MobileCompanionModelTests {
  private func defaults() -> UserDefaults {
    let name = "MobileCompanionModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("Off until the user turns it on, and remembered")
  func offByDefault() {
    let store = defaults()
    let model = MobileCompanionModel(availability: .available, defaults: store)
    #expect(!model.isEnabled)
    var asked: [Bool] = []
    model.enabledChanged = { asked.append($0) }
    model.isEnabled = true
    #expect(asked == [true])
    #expect(MobileCompanionModel(availability: .available, defaults: store).isEnabled)
    model.isEnabled = false
    #expect(asked == [true, false])
    #expect(model.state == .off)
  }

  @Test("A Mac that cannot run it never has it on, whatever was saved")
  func unavailable() {
    let store = defaults()
    store.set(true, forKey: MobileCompanionModel.enabledKey)
    #expect(!MobileCompanionModel(availability: .needsAppleSilicon, defaults: store).isEnabled)
    #expect(!MobileCompanionModel(availability: .notEmbedded, defaults: store).isEnabled)
  }

  @Test("Removing a phone takes it out of the list and asks the agent to forget it")
  func removePhone() {
    let model = MobileCompanionModel(availability: .available, defaults: defaults())
    let older = MobileCompanionModel.Phone(id: "a", name: "iPhone", addedAt: .distantPast)
    let newer = MobileCompanionModel.Phone(id: "b", name: "iPad", addedAt: .now)
    model.update(phones: [older, newer])
    #expect(model.phones.map(\.id) == ["b", "a"])
    var removed: [String] = []
    model.removePhoneAction = { removed.append($0) }
    model.remove(older)
    #expect(model.phones.map(\.id) == ["b"])
    #expect(removed == ["a"])
  }

  @Test("What the agent says is shown only while the companion is on")
  func stateWhileOff() {
    let model = MobileCompanionModel(availability: .available, defaults: defaults())
    model.update(state: .running)
    #expect(model.state == .off)
    model.isEnabled = true
    model.update(state: .running)
    #expect(model.state == .running)
  }
}
