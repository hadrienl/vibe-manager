import CompanionCore
import Testing

/// Both on `home`, the phone shown it by the Mac.
private func following(_ home: String = "https://github.com/o/r") -> RemoteWebFollower {
  var follower = RemoteWebFollower()
  _ = follower.macShows(home, isLoading: false)
  follower.phoneWillNavigate(.page)
  _ = follower.phoneMoved(to: home)
  _ = follower.phoneStoppedLoading()
  return follower
}

@Test("The Mac's sign-in redirect does not take the phone off its sign-in page (#456)")
func macRedirectKeepsPhoneOnSignIn() {
  var follower = following()
  let login = "https://github.com/login?return_to=%2Fo%2Fr"
  follower.phoneWillNavigate(.user)
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
  follower.phoneWillNavigate(.user)
  #expect(follower.phoneMoved(to: "https://github.com/o/r/issues") != nil)
  // Its server sends it on: a redirect, not told.
  #expect(follower.phoneMoved(to: "https://github.com/login") == nil)
  _ = follower.phoneStoppedLoading()
  // A form sent, a reload, a script.
  follower.phoneWillNavigate(.page)
  #expect(follower.phoneMoved(to: "https://github.com/session") == nil)
  _ = follower.phoneStoppedLoading()
  // A single-page site's own link, while nothing loads.
  #expect(follower.phoneMoved(to: "https://github.com/o/r/pulls") == "https://github.com/o/r/pulls")
}

@Test("The Mac's page waits while the phone loads its own")
func macWaitsForPhoneLoad() {
  var follower = following()
  follower.phoneWillNavigate(.page)
  #expect(follower.macShows("https://example.com/a", isLoading: false) == nil)
  #expect(follower.phoneStoppedLoading() == "https://example.com/a")
  #expect(follower.phoneStoppedLoading() == nil)
}

@Test("A page the Mac already shows is not told back")
func samePageNotTold() {
  var follower = following()
  follower.phoneWillNavigate(.user)
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
