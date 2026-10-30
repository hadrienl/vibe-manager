import Foundation

/// Decides, for the phone's web view, which of its pages the Mac is told of and which of the Mac's
/// pages the phone loads (#456).
///
/// The two web views do not share a session: each has its own cookies. Only what the phone's user
/// does is told to the Mac — an address typed, a link touched — never a redirect, a reload or a
/// form's answer. And where the Mac lands after loading what it was told — a sign-in page sends a
/// Mac already signed in back where it came from — is the Mac's answer, not a page for the phone.
///
/// A sign-in page detaches the phone from the Mac altogether: nothing told, nothing followed, until
/// the sign-in ends on a page of the site's — reached by a redirect or a form — or its user attaches
/// it again.
public struct RemoteWebFollower: Sendable {
  /// Why the phone's web view goes to a page.
  public enum Navigation: Sendable {
    /// Its user typed an address or touched a link.
    case user
    /// A redirect, a form sent, a script: where a sign-in ends.
    case redirect
    /// A reload, the history.
    case page
  }

  /// The page the phone shows, or is going to.
  public private(set) var phoneURL: String?
  /// The Mac's active page, as last told.
  public private(set) var macURL: String?
  public private(set) var isPhoneLoading = false
  /// Whether the phone neither tells the Mac nor follows it.
  public private(set) var isDetached = false
  /// Whether its user detached it, for it to stay so until they attach it.
  private var detachedByUser = false
  /// A page of the Mac's to load once the phone's own loading ends.
  private var pendingMacURL: String?
  /// Whether the navigation under way is its user's.
  private var userNavigating = false
  /// Told to the Mac and not answered yet: the Mac's page then, and whether it has begun loading
  /// since.
  private var awaiting: (from: String?, started: Bool)?

  /// The number of the last address typed that was loaded: the view keeps typing's count, which
  /// a new web view must not take for a new address.
  private var typedLoaded = 0

  public init() {}

  /// Whether the address typed as number `number` is still to load: once, whatever the web views.
  public mutating func takeTyped(_ number: Int) -> Bool {
    guard number > typedLoaded else { return false }
    typedLoaded = number
    return true
  }

  /// A new web view, blank, replaced the phone's: it follows the Mac from its next state, attached,
  /// as on its first.
  public mutating func webViewReplaced() {
    self = RemoteWebFollower(typedLoaded: typedLoaded)
  }

  private init(typedLoaded: Int) {
    self.typedLoaded = typedLoaded
  }

  /// The phone's web view starts going to `url`: a sign-in page detaches it, the page a sign-in
  /// ends on attaches it again.
  ///
  /// A link to an anchor of the page shown loads nothing — no navigation starts or ends — and
  /// leaves the phone as it was.
  public mutating func phoneWillNavigate(_ navigation: Navigation, to url: URL?) {
    if let url, url.fragment != nil, navigation != .page,
      let phoneURL, RemoteWebAddress.same(phoneURL, url.absoluteString)
    {
      return
    }
    isPhoneLoading = true
    userNavigating = navigation == .user
    guard let url else { return }
    if RemoteWebAddress.isSignIn(url) {
      if !isDetached { detach(byUser: false) }
    } else if isDetached, !detachedByUser, navigation == .redirect {
      attach()
    }
  }

  /// Neither tells the Mac nor follows it, until attached again.
  public mutating func detach(byUser: Bool = true) {
    isDetached = true
    detachedByUser = byUser
    awaiting = nil
    pendingMacURL = nil
  }

  /// Follows the Mac again from its next move, without loading anything now.
  public mutating func attach() {
    isDetached = false
    detachedByUser = false
  }

  /// The phone's page changed: the address to tell the Mac, if its user went there.
  ///
  /// A change while nothing loads is the page's own history — a link of a single-page site.
  public mutating func phoneMoved(to url: String) -> String? {
    guard phoneURL.map({ !RemoteWebAddress.same($0, url) }) ?? true else { return nil }
    phoneURL = url
    guard !isDetached, userNavigating || !isPhoneLoading else { return nil }
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
    if isDetached {
      macURL = url
      return nil
    }
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

extension RemoteWebAddress {
  /// Hosts that only sign people in.
  static let signInHosts: Set<String> = [
    "accounts.google.com", "login.microsoftonline.com", "login.live.com", "login.microsoft.com",
  ]
  /// Paths, segment by segment, of a sign-in: GitHub's, GitLab's, and the usual ones.
  static let signInPaths: [[String]] = [
    ["login"], ["signin"], ["sign-in"], ["session"], ["sessions"], ["oauth"], ["sso"],
    ["users", "sign_in"], ["users", "two_factor_auth"], ["users", "auth"], ["users", "password"],
  ]
  /// Segments that, last in a path, make it a sign-in: `/login/oauth/authorize`.
  static let signInLastSegments: Set<String> = ["authorize"]

  /// Whether `url` is a page for signing in: its host is an identity provider's, or its path
  /// starts with one of a sign-in's, segment by segment — `/login`, not `/docs/login-help`.
  public static func isSignIn(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    if signInHosts.contains(host) { return true }
    let segments = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
    if let last = segments.last, signInLastSegments.contains(last) { return true }
    return signInPaths.contains { segments.starts(with: $0) }
  }
}
