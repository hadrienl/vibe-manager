import Foundation

/// Decides, for the phone's web view, which of its pages the Mac is told of and which of the Mac's
/// pages the phone loads (#456).
///
/// The two web views do not share a session: each has its own cookies. Only what the phone's user
/// does is told to the Mac — an address typed, a link touched — never a redirect, a reload or a
/// form's answer. And where the Mac lands after loading what it was told — a sign-in page sends a
/// Mac already signed in back where it came from — is the Mac's answer, not a page for the phone.
public struct RemoteWebFollower: Sendable {
  /// Why the phone's web view goes to a page.
  public enum Navigation: Sendable {
    /// Its user typed an address or touched a link.
    case user
    /// A redirect, a reload, a form sent, a script: the page's doing, not its user's.
    case page
  }

  /// The page the phone shows, or is going to.
  public private(set) var phoneURL: String?
  /// The Mac's active page, as last told.
  public private(set) var macURL: String?
  public private(set) var isPhoneLoading = false
  /// A page of the Mac's to load once the phone's own loading ends.
  private var pendingMacURL: String?
  /// Whether the navigation under way is its user's.
  private var userNavigating = false
  /// Told to the Mac and not answered yet: the Mac's page then, and whether it has begun loading
  /// since.
  private var awaiting: (from: String?, started: Bool)?

  public init() {}

  /// The phone's web view starts going somewhere.
  public mutating func phoneWillNavigate(_ navigation: Navigation) {
    isPhoneLoading = true
    userNavigating = navigation == .user
  }

  /// The phone's page changed: the address to tell the Mac, if its user went there.
  ///
  /// A change while nothing loads is the page's own history — a link of a single-page site.
  public mutating func phoneMoved(to url: String) -> String? {
    guard phoneURL.map({ !RemoteWebAddress.same($0, url) }) ?? true else { return nil }
    phoneURL = url
    guard userNavigating || !isPhoneLoading else { return nil }
    userNavigating = false
    pendingMacURL = nil
    if let macURL, RemoteWebAddress.same(macURL, url) { return nil }
    awaiting = (from: macURL, started: false)
    return url
  }

  /// The phone's loading ended, one way or another: the Mac's page to load now, if it moved
  /// meanwhile.
  public mutating func phoneStoppedLoading() -> String? {
    isPhoneLoading = false
    userNavigating = false
    defer { pendingMacURL = nil }
    return pendingMacURL
  }

  /// What the Mac shows: the address the phone should load, if any.
  public mutating func macShows(_ url: String, isLoading: Bool) -> String? {
    if let awaiting {
      // The Mac loads what it was told, and where that load ends — the page asked, or wherever
      // the Mac's session sent it — is its answer. A state it sent before beginning is not.
      let moved = awaiting.from.map { !RemoteWebAddress.same($0, url) } ?? true
      guard awaiting.started || isLoading || moved else { return nil }
      if isLoading {
        self.awaiting = (from: awaiting.from, started: true)
      } else {
        self.awaiting = nil
        macURL = url
      }
      return nil
    }
    guard macURL.map({ !RemoteWebAddress.same($0, url) }) ?? true else { return nil }
    macURL = url
    if let phoneURL, RemoteWebAddress.same(phoneURL, url) { return nil }
    if isPhoneLoading {
      pendingMacURL = url
      return nil
    }
    phoneURL = url
    return url
  }
}
