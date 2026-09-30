import Foundation
import Testing
import VibeDomain

@testable import VibePersistence

@MainActor
@Suite("The symbols and colours preference")
struct UserDefaultsSessionAppearancePaletteStoreTests {
  private let key = "sessions.appearancePalette.v1"

  private func suiteName() -> String {
    "vibe.manager.tests.\(UUID().uuidString)"
  }

  @Test("What was saved is what comes back, after a relaunch too")
  func roundTrip() {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    var palette = SessionAppearancePalette.default
    palette.addSymbol("star")
    palette.removeSwatch("#B42318")

    UserDefaultsSessionAppearancePaletteStore(suiteName: suite).palette = palette

    #expect(UserDefaultsSessionAppearancePaletteStore(suiteName: suite).palette == palette)
  }

  @Test("Never written, or given the shipped lists, reads as nothing")
  func defaultIsNothing() {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSessionAppearancePaletteStore(suiteName: suite)
    #expect(store.palette == nil)

    var palette = SessionAppearancePalette.default
    palette.addSymbol("star")
    store.palette = palette
    store.palette = .default
    #expect(store.palette == nil)
    #expect(UserDefaults(suiteName: suite)?.data(forKey: key) == nil)
  }

  @Test("An unreadable preference is no preference, not an error")
  func unreadable() {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(Data("not json".utf8), forKey: key)
    #expect(UserDefaultsSessionAppearancePaletteStore(suiteName: suite).palette == nil)
  }

  @Test("Changing the colours leaves the symbols to follow the application")
  func onlyTheChangedListIsKept() throws {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    var palette = SessionAppearancePalette.default
    palette.removeSwatch("#B42318")
    UserDefaultsSessionAppearancePaletteStore(suiteName: suite).palette = palette

    let data = try #require(UserDefaults(suiteName: suite)?.data(forKey: key))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["symbols"] == nil)
    #expect(object["swatches"] != nil)
  }

  @Test("A list that cannot be read is the shipped one, and costs the other nothing")
  func oneUnreadableList() {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(
      Data(##"{"symbols": 12, "swatches": [{"hex": "#BB8D14"}]}"##.utf8), forKey: key)

    let palette = UserDefaultsSessionAppearancePaletteStore(suiteName: suite).palette
    #expect(palette?.symbols == SessionAppearanceCatalog.symbolNames)
    #expect(palette?.colorHexValues == ["#BB8D14"])
  }
}
