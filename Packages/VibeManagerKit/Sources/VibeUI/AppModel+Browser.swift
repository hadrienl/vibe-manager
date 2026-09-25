import AppKit
import Foundation
import VibeApplication
import VibeBrowser
import VibeDomain

/// The session's web view, as the workspace drives it (#69).
extension AppModel {
  /// The selected session's web view, when there is one.
  public var selectedBrowser: SessionBrowser? {
    guard let browser, let id = selectedSessionID else { return nil }
    return browser.browser(for: id)
  }

  /// Wires the web view to the workspace: what the layout shows follows the selected session's
  /// view, a page an agent opens can bring it forward, and a link from a terminal lands in it.
  func connectBrowser() {
    guard let browser else { return }
    browser.selectedSessionID = { [weak self] in self?.selectedSessionID }
    browser.visibilityDidChange = { [weak self] id in
      guard let self, id == self.selectedSessionID else { return }
      self.syncBrowserLayout()
    }
    browser.agentDidOpenPage = { [weak self] id in
      guard let self, id == self.selectedSessionID,
        browser.preferences.showsWebViewWhenAgentOpensPage
      else { return }
      // In a window where the two take turns, the page the agent opened is what comes forward.
      self.layout.setShowsBrowserWhenAlternating(true)
    }
    launcher?.openLink = { [weak self] id, url, alternate in
      self?.openTerminalLink(url, from: id, alternate: alternate)
    }
  }

  func selectionDidChange(to id: SessionID?) {
    guard let browser else { return }
    if let id {
      browser.sessionDidAppear(id)
      refreshTicket(of: id)
    }
    syncBrowserLayout()
  }

  /// The layout asks for the web view when the selected session has it open.
  func syncBrowserLayout() {
    guard let browser, let id = selectedSessionID else {
      layout.setBrowserRequested(false)
      return
    }
    layout.setBrowserRequested(browser.isVisible(id))
  }

  public var isWebViewAvailable: Bool {
    browser != nil && selectedSession.map { $0.status != .archived } == true
  }

  /// Whether the selected session's web view is open, whatever room the window gives it.
  public var isWebViewOpen: Bool {
    guard let browser, let id = selectedSessionID else { return false }
    return browser.isVisible(id)
  }

  /// Show Web View / Hide Web View, ⌥⌘B. In a window where the terminal and the web view take
  /// turns, it swaps them rather than closing anything.
  public func toggleWebView() {
    guard let browser, let id = selectedSessionID, isWebViewAvailable else { return }
    if layout.columns.browser == .alternating {
      layout.setShowsBrowserWhenAlternating(!layout.showsBrowserWhenAlternating)
      if !layout.showsBrowserWhenAlternating { focusTerminal() }
      return
    }
    browser.setVisible(!browser.isVisible(id), for: id)
  }

  public func showWebView() {
    guard let browser, let id = selectedSessionID, isWebViewAvailable else { return }
    browser.setVisible(true, for: id)
    layout.setShowsBrowserWhenAlternating(true)
  }

  public func hideWebView() {
    guard let browser, let id = selectedSessionID else { return }
    browser.setVisible(false, for: id)
    focusTerminal()
  }

  /// Focus Web View, ⌥⌘4: the page takes the keyboard.
  public func focusWebView() {
    showWebView()
    webViewFocusRequest += 1
  }

  /// ⌘L: the address bar takes the keyboard, the view shown first if it was not.
  public func focusAddressBar() {
    showWebView()
    addressBarFocusRequest += 1
  }

  /// The tab in front of the selected session.
  public var activeWebTab: BrowserTabModel? {
    selectedBrowser?.activeTab
  }

  public func reloadWebTab() {
    activeWebTab?.reload()
  }

  public func goBackInWebTab() {
    activeWebTab?.goBack()
  }

  public func goForwardInWebTab() {
    activeWebTab?.goForward()
  }

  public func selectNextWebTab() {
    selectedBrowser?.activateNeighbour(offset: 1)
  }

  public func selectPreviousWebTab() {
    selectedBrowser?.activateNeighbour(offset: -1)
  }

  /// Whether ⌘W would close a web tab: the view holds the keyboard, and the tab in front can be
  /// closed. On the ticket's pinned tab it closes nothing — it does not fall back on the session.
  public var closesWebTab: Bool {
    isAddressBarFocused || isWebPageFocused
  }

  /// Set by the window when the keyboard enters or leaves a page.
  public var isWebPageFocused: Bool {
    get { webPageFocus }
    set { webPageFocus = newValue }
  }

  public func closeWebTab() {
    guard let browser, let id = selectedSessionID, let tab = activeWebTab else {
      NSSound.beep()
      return
    }
    guard !tab.isPinnedTicket else {
      NSSound.beep()
      return
    }
    browser.close(tab.id, in: id)
  }

  /// Opens an address in the selected session's web view, from the address bar or the empty view.
  public func openInWebView(_ text: String) {
    guard let browser, let id = selectedSessionID else { return }
    let context = ticketContexts[id]
    if let url = TicketInput.url(from: text, repository: context?.repository),
      text.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    {
      browser.open(url, in: id, openedBy: .user)
      return
    }
    guard let url = Self.address(from: text) else { return }
    browser.open(url, in: id, openedBy: .user)
  }

  /// Sends the tab in front to an address typed in the address bar.
  public func navigateWebTab(to text: String) {
    guard let tab = activeWebTab else {
      openInWebView(text)
      return
    }
    guard let url = Self.address(from: text) else { return }
    if tab.isPinnedTicket, url != tab.url {
      // The ticket's tab stays on the ticket: another address opens beside it.
      openInWebView(text)
      return
    }
    tab.ensureWebView()
    tab.load(url)
  }

  /// What a person types in an address bar: an address with or without its scheme, a path, or
  /// words — which are looked up.
  static func address(from text: String) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("/") || text.hasPrefix("~") {
      return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }
    if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
      || text.hasPrefix("about:")
    {
      return URL(string: text)
    }
    if !text.contains(" "), text.contains(".") || text.contains(":") || text == "localhost" {
      let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.")
      return URL(string: (isLocal ? "http://" : "https://") + text)
    }
    var components = URLComponents(string: "https://duckduckgo.com/")
    components?.queryItems = [URLQueryItem(name: "q", value: text)]
    return components?.url
  }

  /// ⌘-click in a terminal: the session's web view, or the default browser as Settings say; ⌥⌘-click
  /// does the other.
  func openTerminalLink(_ url: URL, from id: SessionID, alternate: Bool) {
    // A link's text and its address can differ (OSC 8), and output is anybody's: only what shows a
    // page is opened. Another application's address, or a file that is not a page — a `.command`,
    // an app — is not run on a click.
    let scheme = url.scheme?.lowercased() ?? ""
    let isWeb = scheme == "http" || scheme == "https"
    let isPage =
      url.isFileURL && ["html", "htm", "svg", "pdf"].contains(url.pathExtension.lowercased())
    guard isWeb || isPage || scheme == "mailto" else {
      NSSound.beep()
      return
    }
    guard let browser, scheme != "mailto" else {
      NSWorkspace.shared.open(url)
      return
    }
    var inWebView = browser.preferences.terminalLinks == .webView
    if alternate { inWebView.toggle() }
    guard inWebView else {
      NSWorkspace.shared.open(url)
      return
    }
    browser.openLink(url, in: id)
    if id == selectedSessionID { layout.setShowsBrowserWhenAlternating(true) }
  }

  // MARK: - Ticket

  /// Reads the session's branch and forge again, and the ticket they give.
  func refreshTicket(of id: SessionID) {
    guard let browser, let session = sessions.first(where: { $0.id == id }) else { return }
    let stored = session.ticket
    browser.updateTicket(
      stored: stored, branch: ticketContexts[id]?.branch,
      repository: ticketContexts[id]?.repository, for: id)
    guard let readTicketContext, let path = session.repositories.first?.path else { return }
    Task { [weak self] in
      let context = await readTicketContext(path: path)
      guard let self else { return }
      self.ticketContexts[id] = context
      let current = self.sessions.first(where: { $0.id == id })?.ticket
      browser.updateTicket(
        stored: current, branch: context.branch, repository: context.repository, for: id)
    }
  }

  /// Change Ticket…: an address, or `#12` in the session's repository. Empty removes it.
  public func setTicket(_ text: String, for id: SessionID) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = TicketInput.url(from: trimmed, repository: ticketContexts[id]?.repository)
    guard url != nil || trimmed.isEmpty else { return }
    _ = try? await SetSessionTicket(repository: repository)(url, for: id)
    await reload()
    refreshTicket(of: id)
  }

  /// Use Branch Ticket: forgets what was chosen, and the branch decides again.
  public func resetTicket(for id: SessionID) async {
    _ = try? await SetSessionTicket(repository: repository).reset(for: id)
    await reload()
    refreshTicket(of: id)
  }

  /// The ticket the selected session shows, and where it comes from.
  public var selectedTicket: TicketResolution.Resolved? {
    selectedBrowser?.ticket
  }

  /// Whether a session has something in its web view the user has not seen: a page an agent opened,
  /// or a question waiting.
  public func webViewAttention(for id: SessionID) -> WebViewAttention? {
    guard let browser else { return nil }
    if !browser.requests(for: id).isEmpty { return .waitingForApproval }
    if browser.browser(for: id).hasUnseenAgentPage { return .agentOpenedPage }
    return nil
  }
}

public enum WebViewAttention: Hashable, Sendable {
  case agentOpenedPage
  case waitingForApproval
}
