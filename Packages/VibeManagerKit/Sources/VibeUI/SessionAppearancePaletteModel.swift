import Foundation
import Observation
import SwiftUI
import VibeApplication
import VibeDomain

/// The symbols and colours the pickers offer (#199), as the Settings edit them.
///
/// Every change is written at once: there is no Save button in the Settings, and a list that only
/// changed on screen would be lost with the window.
@MainActor
@Observable
public final class SessionAppearancePaletteModel {
  public private(set) var palette: SessionAppearancePalette
  @ObservationIgnored private let store: any SessionAppearancePaletteStore
  /// Told of every change, so that the drafts already open offer the lists as they now are.
  @ObservationIgnored var changed: ((SessionAppearancePalette) -> Void)?

  public init(store: any SessionAppearancePaletteStore = InMemorySessionAppearancePaletteStore()) {
    self.store = store
    palette = store.palette ?? .default
  }

  /// What the pickers offer and what a name is given from: the lists, less the symbols this Mac
  /// cannot draw — added on a later macOS, they would be an empty badge (ADR 0035). They stay in
  /// the lists, and the Settings still show them.
  public var offered: SessionAppearancePalette {
    palette.keepingSymbols(where: SymbolCatalog.isDrawable)
  }

  /// Applies `change` to the palette and keeps it.
  public func update(_ change: (inout SessionAppearancePalette) -> Void) {
    var edited = palette
    change(&edited)
    guard edited != palette else { return }
    palette = edited
    store.palette = edited
    changed?(offered)
  }

  /// Back to the shipped lists.
  public func restoreDefaults() {
    palette = .default
    store.palette = nil
    changed?(offered)
  }
}

extension EnvironmentValues {
  /// The lists the pickers offer, for the views that are not handed a model (the templates).
  @Entry public var sessionAppearancePalette: SessionAppearancePalette = .default
}
