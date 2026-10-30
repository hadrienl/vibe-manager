import CompanionCore
import Foundation
import Testing

/// Both on `home`, the phone shown it by the Mac.
private func following(_ home: String = "https://github.com/o/r") -> RemoteWebFollower {
  var follower = RemoteWebFollower()
  _ = follower.macShows(home, isLoading: false)
  follower.phoneWillNavigate(.page, to: nil)
  _ = follower.phoneMoved(to: home)
  _ = follower.phoneStoppedLoading()
  return follower
}

@Test("Where the Mac lands after loading what the phone asked is not loaded on the phone (#456)")
func macRedirectKeepsPhoneOnSignIn() {
  var follower = following()
  let login = "https://github.com/login?return_to=%2Fo%2Fr"
  follower.phoneWillNavigate(.user, to: nil)
  #expect(follower.phoneMoved(to: login) == login)
  // The Mac, signed in already, is sent back where it was.
  #expect(follower.macShows("https://github.com/o/r", isLoading: false) == nil)
  #expect(follower.macShows(login, isLoading: true) == nil)
  #expect(follower.macShows("https://github.com/o/r", isLoading: true) == nil)
  #expect(follower.macShows("https://github.com/o/r", isLoading: false) == nil)
  #expect(follower.phoneStoppedLoading() == nil)
  #expect(follower.phoneURL == login)
  // What the Mac's user does next is followed again.
  #expect(
    follower.macShows("https://github.com/o/r/pulls", isLoading: false)
      == "https://github.com/o/r/pulls")
}

@Test("Only the phone's user's navigations reach the Mac")
func onlyUserNavigationsAreTold() {
  var follower = following()
  follower.phoneWillNavigate(.user, to: nil)
  #expect(follower.phoneMoved(to: "https://github.com/o/r/issues") != nil)
  // Its server sends it on: a redirect, not told.
  #expect(follower.phoneMoved(to: "https://github.com/login") == nil)
  _ = follower.phoneStoppedLoading()
  // A form sent, a reload, a script.
  follower.phoneWillNavigate(.page, to: nil)
  #expect(follower.phoneMoved(to: "https://github.com/session") == nil)
  _ = follower.phoneStoppedLoading()
  // A single-page site's own link, while nothing loads.
  #expect(follower.phoneMoved(to: "https://github.com/o/r/pulls") == "https://github.com/o/r/pulls")
}

@Test("The Mac's page waits while the phone loads its own")
func macWaitsForPhoneLoad() {
  var follower = following()
  follower.phoneWillNavigate(.page, to: nil)
  #expect(follower.macShows("https://example.com/a", isLoading: false) == nil)
  #expect(follower.phoneStoppedLoading() == "https://example.com/a")
  #expect(follower.phoneStoppedLoading() == nil)
}

@Test("A page the Mac already shows is not told back")
func samePageNotTold() {
  var follower = following()
  follower.phoneWillNavigate(.user, to: nil)
  #expect(follower.phoneMoved(to: "https://github.com/o/r/") == nil)
  #expect(follower.macShows("https://example.com", isLoading: false) == nil)
  #expect(follower.phoneStoppedLoading() == "https://example.com")
}

@Test("Typed addresses read as Safari reads them")
func typedAddresses() {
  #expect(RemoteWebAddress.typed("github.com")?.absoluteString == "https://github.com")
  #expect(RemoteWebAddress.typed("localhost:4000")?.absoluteString == "http://localhost:4000")
  #expect(RemoteWebAddress.typed(" http://a/b ")?.absoluteString == "http://a/b")
  #expect(RemoteWebAddress.typed("  ") == nil)
}

/// The phone goes to `url`: from where, and whether the Mac is told.
private func go(
  _ follower: inout RemoteWebFollower, _ navigation: RemoteWebFollower.Navigation, to url: String
) -> String? {
  follower.phoneWillNavigate(navigation, to: URL(string: url))
  let told = follower.phoneMoved(to: url)
  _ = follower.phoneStoppedLoading()
  return told
}

@Test("GitHub's sign-in, from the link to its end, stays the phone's own (#456)")
func gitHubSignIn() {
  let repository = "https://github.com/o/r"
  var follower = following(repository)
  #expect(go(&follower, .user, to: "https://github.com/login?return_to=%2Fo%2Fr") == nil)
  #expect(follower.isDetached)
  // The Mac, signed in, goes wherever it goes: not followed.
  #expect(follower.macShows("https://github.com/o/r/issues", isLoading: false) == nil)
  #expect(go(&follower, .redirect, to: "https://github.com/session") == nil)
  #expect(go(&follower, .redirect, to: "https://github.com/sessions/two-factor/app") == nil)
  #expect(follower.isDetached)
  #expect(go(&follower, .redirect, to: "https://github.com/sessions/two-factor") == nil)
  #expect(follower.isDetached)
  // Signed in: the redirect to `return_to` attaches it again, telling the Mac nothing.
  #expect(go(&follower, .redirect, to: repository) == nil)
  #expect(!follower.isDetached)
  #expect(follower.phoneURL == repository)
  // From the Mac's next move on, it follows again.
  #expect(follower.macShows("https://github.com/o/r/issues", isLoading: false) == nil)
  #expect(
    follower.macShows("https://github.com/o/r/pulls", isLoading: false)
      == "https://github.com/o/r/pulls")
}

@Test("GitLab's sign-in, with its second factor and its SSO, stays the phone's own (#456)")
func gitLabSignIn() {
  var follower = following("https://gitlab.com/g/p")
  #expect(go(&follower, .user, to: "https://gitlab.com/users/sign_in") == nil)
  #expect(follower.isDetached)
  #expect(go(&follower, .redirect, to: "https://gitlab.com/users/sign_in") == nil)
  #expect(go(&follower, .redirect, to: "https://gitlab.com/users/two_factor_auth") == nil)
  #expect(follower.isDetached)
  #expect(go(&follower, .redirect, to: "https://gitlab.com/g/p") == nil)
  #expect(!follower.isDetached)

  // Through an identity provider.
  #expect(go(&follower, .user, to: "https://gitlab.com/users/auth/google_oauth2") == nil)
  #expect(go(&follower, .redirect, to: "https://accounts.google.com/o/oauth2/v2/auth?x=1") == nil)
  #expect(
    go(&follower, .redirect, to: "https://gitlab.com/users/auth/google_oauth2/callback") == nil)
  #expect(follower.isDetached)
  #expect(go(&follower, .redirect, to: "https://gitlab.com/dashboard/projects") == nil)
  #expect(!follower.isDetached)
}

@Test("Detached by its user, a tab stays so until they attach it")
func detachedByUser() {
  var follower = following()
  follower.detach()
  #expect(go(&follower, .redirect, to: "https://github.com/o/r/pulls") == nil)
  #expect(go(&follower, .user, to: "https://github.com/o/r/issues") == nil)
  #expect(follower.isDetached)
  #expect(follower.macShows("https://example.com", isLoading: false) == nil)
  follower.attach()
  // Attached, nothing loads until the Mac moves.
  #expect(follower.macShows("https://example.com", isLoading: false) == nil)
  #expect(follower.macShows("https://example.com/b", isLoading: false) == "https://example.com/b")
}

@Test("A link touched while detached by a sign-in does not attach the tab")
func userLinkKeepsDetached() {
  var follower = following()
  _ = go(&follower, .user, to: "https://github.com/login")
  #expect(go(&follower, .user, to: "https://github.com/password_reset") == nil)
  #expect(follower.isDetached)
}

@Test("Sign-in pages are told by their host or their path's segments")
func signInPages() throws {
  for page in [
    "https://github.com/login", "https://github.com/login?return_to=%2F",
    "https://github.com/login/oauth/authorize?client_id=1", "https://github.com/session",
    "https://github.com/sessions/two-factor", "https://gitlab.com/users/sign_in",
    "https://git.example.org/users/two_factor_auth", "https://gitlab.com/users/auth/saml",
    "https://accounts.google.com/v3/signin", "https://login.microsoftonline.com/common/oauth2",
    "https://example.com/signin", "https://example.com/sso/start",
    "https://example.com/oauth/authorize",
  ] {
    #expect(RemoteWebAddress.isSignIn(try #require(URL(string: page))), "\(page)")
  }
  for page in [
    "https://github.com/o/r", "https://github.com/o/login", "https://example.com/docs/login-help",
    "https://gitlab.com/users/hadrien", "https://example.com/blog/sso-explained",
    "https://github.com/o/r/pull/1",
  ] {
    #expect(!RemoteWebAddress.isSignIn(try #require(URL(string: page))), "\(page)")
  }
}
