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
  /// Told to the Mac and not answered yet: the Mac's page then, the one it was told, and whether
  /// it has begun loading that one.
  private var awaiting: (from: String?, to: String, started: Bool)?
  /// The sites a sign-in under way may end on: the one it started from, and those whose own pages
  /// it went through — not an identity provider's, nor a host met on the way.
  private var signInSites: Set<String> = []

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
    // A new page asked by its user: the Mac's answer to the last one no longer matters.
    if navigation == .user { awaiting = nil }
    guard let url else { return }
    if RemoteWebAddress.isSignIn(url) {
      if !isDetached {
        detach(byUser: false)
        if let host = phoneURL.flatMap(URL.init(string:))?.host { signInSites.insert(host) }
      }
      if !detachedByUser, let host = url.host, !RemoteWebAddress.isIdentityProvider(host) {
        signInSites.insert(host)
      }
    } else if isDetached, !detachedByUser, navigation == .redirect,
      signInSites.isEmpty
        || signInSites.contains(where: { RemoteWebAddress.sameSite($0, url.host) })
    {
      attach()
    }
  }

  /// Neither tells the Mac nor follows it, until attached again.
  public mutating func detach(byUser: Bool = true) {
    isDetached = true
    detachedByUser = byUser
    signInSites = []
    awaiting = nil
    pendingMacURL = nil
  }

  /// Follows the Mac again from its next move, without loading anything now.
  public mutating func attach() {
    isDetached = false
    detachedByUser = false
    signInSites = []
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
    awaiting = (from: macURL, to: url, started: false)
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
      // The Mac takes the address it was told at once, then loads it: where that load ends — the
      // page asked, or wherever the Mac's session sent it — is its answer. A state from before is
      // not; a page it moved to first is its own user's, and the answer is not coming.
      if awaiting.started || RemoteWebAddress.same(url, awaiting.to) {
        if isLoading {
          self.awaiting?.started = true
        } else {
          self.awaiting = nil
          macURL = url
        }
        return nil
      }
      if awaiting.from.map({ RemoteWebAddress.same($0, url) }) ?? false { return nil }
      self.awaiting = nil
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
  /// Hosts that only sign people in, and the domains whose every host does.
  static let identityHosts: Set<String> = [
    "accounts.google.com", "login.microsoftonline.com", "login.live.com", "login.microsoft.com",
    "appleid.apple.com", "idmsa.apple.com",
  ]
  static let identityDomains: Set<String> = ["auth0.com", "okta.com"]
  /// Paths of a sign-in on any site, segment by segment, `*` for any one: GitLab's, Keycloak's,
  /// and the usual ones.
  static let signInPaths: [[String]] = [
    ["login"], ["signin"], ["sign-in"], ["sso"], ["auth", "login"], ["accounts", "login"],
    ["users", "sign_in"], ["users", "two_factor_auth"], ["users", "auth"], ["users", "password"],
    ["realms", "*", "protocol", "openid-connect", "auth"],
  ]
  /// Paths of a sign-in only on the sites known to use them that way: elsewhere, a page of
  /// sessions or about OAuth is no sign-in.
  static let siteSignInPaths: [String: [[String]]] = [
    "github.com": [["session"], ["sessions"], ["login", "oauth", "authorize"]],
    "gitlab.com": [["oauth", "authorize"]],
  ]

  /// Whether `host` only signs people in.
  public static func isIdentityProvider(_ host: String) -> Bool {
    let host = host.lowercased()
    return identityHosts.contains(host)
      || identityDomains.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  /// Whether two hosts are of one site: the same, or one under the other.
  static func sameSite(_ first: String, _ second: String?) -> Bool {
    guard let second = second?.lowercased() else { return false }
    let first = first.lowercased()
    return first == second || first.hasSuffix("." + second) || second.hasSuffix("." + first)
  }

  /// Whether `url` is a page for signing in: its host is an identity provider's, or its path
  /// starts with one of a sign-in's, segment by segment — `/login`, not `/docs/login-help`. Never
  /// a page of the Mac's own: an app in development has its own sessions and sign-in.
  public static func isSignIn(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), !isMacLocal(url) else { return false }
    if isIdentityProvider(host) { return true }
    let segments = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
    func starts(with path: [String]) -> Bool {
      segments.count >= path.count
        && zip(segments, path).allSatisfy { $1 == "*" || $0 == $1 }
    }
    let site = siteSignInPaths.first { sameSite($0.key, host) }?.value ?? []
    return (signInPaths + site).contains(where: starts)
  }
}
