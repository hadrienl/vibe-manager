import Foundation
import VibeApplication
import VibeDomain
import WebKit

/// A ticket of a session, as the tab it is read in is remembered.
struct TicketTabKey: Hashable {
  let session: SessionID
  let resolverID: UUID
  let shortID: String
}

/// The title of a ticket, read in the session's web view where the user is signed in (#89).
///
/// The page is opened as the user would open it: in the tab that already shows the ticket — the
/// pinned ticket tab most often — or in a new tab, in the background. Its title is only read once
/// the page is the ticket's: a sign-in page, or a redirection to another ticket, never gives one.
extension BrowserWorkspace: TicketPageReading {
  static let ticketPollInterval: Duration = .milliseconds(250)
  /// Before the first answer. A sign-in page, once reached, is waited out without a limit.
  static let ticketLoadTimeout: Duration = .seconds(30)
  /// From the moment the ticket's page is there: a single-page application writes its title
  /// once its data came.
  static let ticketTitleTimeout: Duration = .seconds(10)
  /// A title read twice this far apart is the page's, not its "Loading…".
  static let ticketTitleStability: Duration = .milliseconds(800)

  public func readTicket(
    _ ticket: TicketRecognition,
    resolvers: TicketResolverSet,
    in session: SessionID,
    progress: @escaping @MainActor (TicketPageProgress) -> Void
  ) async -> TicketPageOutcome {
    let browser = await restoredBrowser(for: session)
    guard let tab = ticketTab(for: ticket, resolvers: resolvers, in: session, opening: true)
    else { return .abandoned }
    let key = TicketTabKey(
      session: session, resolverID: ticket.resolverID, shortID: ticket.shortID)
    ticketTabIDs[key] = tab.id
    progress(.loading)
    let outcome = await readTicketPage(
      tab, ticket: ticket, resolvers: resolvers, waitsForSignIn: true,
      isStillThere: { [weak browser, weak tab] in
        guard let browser, let tab else { return false }
        return browser.tab(tab.id) === tab
      },
      progress: progress)
    releaseTicketPage(tab, of: session)
    return outcome
  }

  public func testTicketPage(_ ticket: TicketRecognition, resolvers: TicketResolverSet) async
    -> TicketPageOutcome
  {
    guard let url = ticket.url else { return .abandoned }
    let tab = BrowserTabModel(url: url, openedBy: .user, configuration: configuration)
    defer { tab.discard() }
    return await readTicketPage(
      tab, ticket: ticket, resolvers: resolvers, waitsForSignIn: false, isStillThere: { true },
      progress: { _ in })
  }

  public func showTicket(
    _ ticket: TicketRecognition, resolvers: TicketResolverSet, in session: SessionID
  ) {
    guard let tab = ticketTab(for: ticket, resolvers: resolvers, in: session, opening: true)
    else { return }
    browser(for: session).activate(tab.id)
    tab.ensureWebView()
    touch(tab)
    setVisible(true, for: session)
  }

  /// The tab on this ticket: one whose address is the ticket's, else — when `opening` — a new tab
  /// after the others, in the background. The web view is not shown for it.
  private func ticketTab(
    for ticket: TicketRecognition, resolvers: TicketResolverSet, in session: SessionID,
    opening: Bool
  ) -> BrowserTabModel? {
    let browser = browser(for: session)
    // The tab this ticket was read in, wherever a sign-in page took it.
    let key = TicketTabKey(
      session: session, resolverID: ticket.resolverID, shortID: ticket.shortID)
    if let id = ticketTabIDs[key], let known = browser.tab(id) {
      return known
    }
    // The pinned tab follows the ticket's address, even once a sign-in page took it elsewhere.
    if let pinned = browser.ticketTab, let ticketURL = browser.ticket?.url,
      resolvers.isPage(ticketURL, of: ticket)
    {
      return pinned
    }
    if let existing = browser.allTabs.first(where: {
      resolvers.isPage($0.url, of: ticket)
        || $0.committedURL.map { resolvers.isPage($0, of: ticket) } == true
    }) {
      return existing
    }
    guard opening, let url = ticket.url else { return nil }
    let tab = makeTab(url, openedBy: .user, in: session)
    browser.append(tab, activate: false)
    touch(tab)
    ticketTabIDs[key] = tab.id
    return tab
  }

  /// A page read for its title costs memory for nothing once read, unless it is what the user is
  /// looking at: it is let go, and loads again when its tab is shown.
  private func releaseTicketPage(_ tab: BrowserTabModel, of session: SessionID) {
    // A session archived meanwhile has let its pages go already; none is made for it again.
    guard let browser = existingBrowser(for: session) else { return }
    let isOnScreen =
      selectedSessionID?() == session && browser.isVisible && browser.activeTab === tab
    guard !isOnScreen, !tab.isAgentActing, browser.tab(tab.id) === tab else { return }
    tab.discard()
  }

  /// Where a reading that waits for the user stands.
  private enum Waiting: Equatable {
    case no
    case signIn
    /// 404: a missing ticket, or a private one the account signed in cannot see — GitHub answers
    /// that way to a visitor. Waited out too: signing in in the tab brings the title.
    case notFound
  }

  func readTicketPage(
    _ tab: BrowserTabModel,
    ticket: TicketRecognition,
    resolvers: TicketResolverSet,
    waitsForSignIn: Bool,
    isStillThere: @escaping @MainActor () -> Bool,
    progress: @escaping @MainActor (TicketPageProgress) -> Void
  ) async -> TicketPageOutcome {
    guard let resolver = resolvers.resolver(id: ticket.resolverID) else { return .abandoned }
    let clock = ContinuousClock()
    var loadDeadline = clock.now + Self.ticketLoadTimeout
    var titleDeadline: ContinuousClock.Instant?
    var candidate: (title: String, raw: String, since: ContinuousClock.Instant)?
    var waiting = Waiting.no
    tab.ensureWebView()
    defer { signInWaits[tab.id] = nil }

    func wait(_ state: Waiting, host: String, status: Int) {
      candidate = nil
      titleDeadline = nil
      guard waiting != state else { return }
      waiting = state
      signInWaits[tab.id] = ticket.url
      progress(state == .notFound ? .notFound(status: status) : .signInRequired(host: host))
    }

    while true {
      try? await Task.sleep(for: Self.ticketPollInterval)
      guard !Task.isCancelled, isStillThere(), tab.isLoaded else { return .abandoned }
      let now = clock.now
      if tab.isLoading || tab.webView?.isLoading == true {
        if waiting == .no, now > loadDeadline { return .failed(.timedOut) }
        continue
      }
      if let failure = tab.failure {
        // Waiting for the user, a failed page may be tried again in the tab.
        if waiting != .no { continue }
        return .failed(Self.ticketFailure(failure))
      }
      // Where the document is now: a single-page application moves without a navigation, so the
      // address of the last one committed is not enough.
      guard let current = tab.webView?.url ?? tab.committedURL else {
        if waiting == .no, now > loadDeadline { return .failed(.timedOut) }
        continue
      }
      let status = tab.mainFrameStatus ?? 200
      let host = current.host ?? ""
      let isTicketPage = resolvers.isPage(current, of: ticket)
      if isTicketPage, status == 404 || status == 410 {
        guard waitsForSignIn else { return .notFound(status: status) }
        wait(.notFound, host: host, status: status)
        continue
      }
      if !isTicketPage || status == 401 || status == 403 {
        guard waitsForSignIn else { return .signInRequired(host: host) }
        wait(.signIn, host: host, status: status)
        continue
      }
      if status >= 400 {
        if waiting != .no { continue }
        return .failed(.http(status: status))
      }
      if waiting != .no {
        waiting = .no
        signInWaits[tab.id] = nil
        loadDeadline = now + Self.ticketLoadTimeout
        progress(.loading)
        // Signed in here: the other tickets of this site waiting on a sign-in page go back to
        // their own address, where the session now lets them in.
        resumeSignInWaits(on: host, except: tab)
      }
      let deadline = titleDeadline ?? now + Self.ticketTitleTimeout
      titleDeadline = deadline

      guard let metadata = await tab.readTitleMetadata() else { continue }
      // Read from the document itself: it must still be the ticket's.
      guard let address = metadata.address, resolvers.isPage(address, of: ticket) else {
        candidate = nil
        continue
      }
      var read: (title: String, raw: String)?
      for raw in metadata.titles {
        if let title = resolver.cleanTitle(raw) {
          read = (title, TicketTitleText.normalized(raw))
          break
        }
      }
      if let read {
        if let candidate, candidate.title == read.title {
          if clock.now - candidate.since >= Self.ticketTitleStability {
            return .title(candidate.title, raw: candidate.raw)
          }
        } else {
          candidate = (read.title, read.raw, clock.now)
        }
      }
      if clock.now > deadline {
        if let candidate { return .title(candidate.title, raw: candidate.raw) }
        return .failed(.noTitle)
      }
    }
  }

  /// Sends back to their ticket the tabs of `host` that wait on a sign-in page.
  private func resumeSignInWaits(on host: String, except reading: BrowserTabModel) {
    for (id, url) in signInWaits where id != reading.id && url.host == host {
      guard let tab = tabAnywhere(id), tab.isLoaded else { continue }
      tab.load(url)
    }
  }

  private static func ticketFailure(_ failure: BrowserLoadFailure) -> TicketPageFailure {
    switch failure {
    case .offline: return .offline
    case .unreachable(let host, _), .serverNotStarted(let host): return .unreachable(host: host)
    case .insecure(let host, _): return .untrustedCertificate(host: host)
    case .other(let reason): return .load(reason: reason)
    }
  }
}
