import Foundation
import VibeApplication
import VibeDomain

/// Whether ticket titles go to the notes, and in what line (#89), kept across launches. A key
/// never written reads as the default: on, `[{id}] {title} — {url}`.
@MainActor
public final class UserDefaultsTicketTitlePreferences: TicketTitlePreferences {
  private enum Key {
    static let disabled = "tickets.titles.disabled.v1"
    static let lineFormat = "tickets.titles.lineFormat.v1"
  }

  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var insertsTicketTitles: Bool {
    get { !defaults.bool(forKey: Key.disabled) }
    set { defaults.set(!newValue, forKey: Key.disabled) }
  }

  public var lineFormat: TicketLineFormat {
    get {
      defaults.string(forKey: Key.lineFormat).map(TicketLineFormat.init).flatMap {
        $0.isValid ? $0 : nil
      } ?? .standard
    }
    set { defaults.set(newValue.template, forKey: Key.lineFormat) }
  }
}
