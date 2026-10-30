import Foundation

/// The companion's sentences said by the composition, which has no catalog of its own.
public enum CompanionStrings {
  /// A request of the phone's web view for a page the Mac does not fetch for it.
  public static var addressRefused: String {
    String(localized: "Address refused", bundle: .module)
  }
}
