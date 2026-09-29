import Foundation
import VibeDomain

/// Where the symbols and colours the pickers offer are kept (#199).
///
/// `nil` means the user never changed them: the shipped lists apply, and follow the application
/// when a later version ships others.
@MainActor
public protocol SessionAppearancePaletteStore: AnyObject {
  var palette: SessionAppearancePalette? { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemorySessionAppearancePaletteStore: SessionAppearancePaletteStore {
  public var palette: SessionAppearancePalette?

  public init(palette: SessionAppearancePalette? = nil) {
    self.palette = palette
  }
}
