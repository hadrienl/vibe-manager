import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Where a session's name or badge is being edited (#183): its row in the sidebar, or the header
/// of the inspector.
public struct SessionIdentityEditing: Hashable, Sendable {
  public enum Place: Hashable, Sendable {
    case sidebar
    case inspector
  }

  public let sessionID: SessionID
  public let place: Place

  public init(sessionID: SessionID, place: Place) {
    self.sessionID = sessionID
    self.place = place
  }
}

/// The badge chosen in the Change Icon popover (#183): previewed on the session's badges while it
/// is open, written once it closes, forgotten with Escape.
///
/// The choices are those of a creation: a symbol or a colour drops the image, which would otherwise
/// be drawn over them, and keeps the other half; the project's icon puts the image back.
@MainActor
@Observable
public final class SessionAppearanceEditor {
  public let editing: SessionIdentityEditing
  /// The badge the session had when the popover opened.
  public let original: SessionAppearance
  /// The badge previewed, and written if the popover closes without Escape.
  public var current: SessionAppearance
  /// The project icon offered: the one the session wears, else the one found in its folder.
  public private(set) var projectIconID: SessionIconID?
  /// What Revert to Default Icon gives, once the folder has been looked at.
  public private(set) var defaultAppearance: SessionAppearance?
  /// The icon found in the folder, copied to the data folder if the badge ends up naming it.
  private var foundIcon: ProjectIcon?

  public init(editing: SessionIdentityEditing, original: SessionAppearance) {
    self.editing = editing
    self.original = original
    current = original
    projectIconID = original.iconID
  }

  public var sessionID: SessionID { editing.sessionID }

  public var usesProjectIcon: Bool { current.iconID != nil }

  public var hasChanges: Bool { current != original }

  /// Whether the badge previewed is already the default one: Revert has nothing to do.
  public var isDefault: Bool { defaultAppearance == current }

  public func pickSymbol(_ symbol: String) {
    current = SessionAppearance(symbolName: symbol, colorHex: current.colorHex)
  }

  public func pickColor(_ hex: String) {
    current = SessionAppearance(symbolName: current.symbolName, colorHex: hex)
  }

  public func useProjectIcon() {
    guard let projectIconID else { return }
    current.iconID = projectIconID
  }

  public func revertToDefault() {
    guard let defaultAppearance else { return }
    current = defaultAppearance
  }

  /// What was found in the folder: the default badge, and the icon — offered when the session
  /// wears none.
  func found(default appearance: SessionAppearance, icon: ProjectIcon?) {
    defaultAppearance = appearance
    guard let icon else { return }
    foundIcon = icon
    if projectIconID == nil { projectIconID = icon.id }
  }

  /// The icon to copy before writing the badge: the one found, when the badge names it.
  var iconToKeep: ProjectIcon? {
    guard let foundIcon, current.iconID == foundIcon.id else { return nil }
    return foundIcon
  }
}
