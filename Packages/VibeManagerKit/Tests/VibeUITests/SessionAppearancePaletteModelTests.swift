import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The symbols and colours of the Settings", .timeLimit(.minutes(1)))
struct SessionAppearancePaletteModelTests {
  private typealias Swatch = SessionAppearancePalette.Swatch

  @Test("Each change is kept at once; Default forgets the user's lists")
  func changesAreKept() {
    let store = InMemorySessionAppearancePaletteStore()
    let model = SessionAppearancePaletteModel(store: store)
    #expect(model.palette.isDefault)

    model.update { $0.addSymbol("star") }
    #expect(store.palette?.symbols.last == "star")
    #expect(SessionAppearancePaletteModel(store: store).palette.symbols.last == "star")

    model.restoreDefaults()
    #expect(model.palette.isDefault)
    #expect(store.palette == nil)
  }

  @Test("A change refused by the palette writes nothing")
  func refusedChangeWritesNothing() {
    let store = InMemorySessionAppearancePaletteStore()
    let model = SessionAppearancePaletteModel(store: store)
    model.update { $0.addSwatch(Swatch(hex: "#FFFFFF")) }
    #expect(store.palette == nil)
  }

  @Test("A new session is offered the lists of the Settings, and named among them")
  func newSessionUsesThePalette() async throws {
    let repository = WorkspaceRepository(sessions: [])
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let custom = SessionAppearancePalette(symbols: ["star"], swatches: [Swatch(hex: "#123456")])
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      appearancePalette: InMemorySessionAppearancePaletteStore(palette: custom))
    await model.load()

    model.beginNewSession()
    let sheet = try #require(model.newSessionModel)
    #expect(sheet.draft.palette == custom)
    sheet.draft.name = "Anything"
    #expect(
      sheet.draft.effectiveAppearance
        == SessionAppearance(symbolName: "star", colorHex: "#123456"))

    // Changed while the draft is open: it offers the lists as they now are, and ⌘N keeps it.
    model.appearancePalette.restoreDefaults()
    #expect(sheet.draft.palette == .default)
    model.beginNewSession()
    #expect(model.newSessionModel === sheet)
    #expect(sheet.draft.effectiveAppearance == SessionAppearancePalette.default.derived(forName: "Anything"))
  }
}

@Suite("The keyboard on the chips of the Badges settings")
struct SessionAppearanceChipKeyboardTests {
  @Test("← and → go to the neighbours and stop at the ends")
  func neighbours() {
    let list = ["a", "b", "c"]
    #expect(SessionAppearanceSettingsView.neighbour(of: "b", by: -1, in: list) == "a")
    #expect(SessionAppearanceSettingsView.neighbour(of: "a", by: -1, in: list) == "a")
    #expect(SessionAppearanceSettingsView.neighbour(of: "c", by: 1, in: list) == "c")
  }

  @Test("After ⌫ the keyboard goes to the next chip, or the previous one at the end")
  func survivor() {
    let list = ["a", "b", "c"]
    #expect(SessionAppearanceSettingsView.survivor(of: "b", in: list) == "c")
    #expect(SessionAppearanceSettingsView.survivor(of: "c", in: list) == "b")
    #expect(SessionAppearanceSettingsView.survivor(of: "a", in: ["a"]) == "a")
  }
}
