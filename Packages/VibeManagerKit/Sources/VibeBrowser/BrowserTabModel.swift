import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain
import WebKit

/// Why a page is not showing.
public enum BrowserLoadFailure: Hashable, Sendable {
  /// Nothing listens yet on a port of this Mac: the development server is probably starting.
  case serverNotStarted(origin: String)
  /// The Mac is not connected.
  case offline(host: String)
  /// The host could not be reached or found.
  case unreachable(host: String, reason: String)
  /// The certificate is not trusted.
  case insecure(host: String, isLocal: Bool)
  /// Anything else, as WebKit said it.
  case other(reason: String)

  /// What the agent is told.
  public var agentDescription: String {
    switch self {
    case .serverNotStarted(let origin):
      return "Nothing is listening on \(origin) yet (connection refused): start the server, then "
        + "call tab_reload."
    case .offline(let host):
      return "\(host) cannot be reached: the Mac is offline."
    case .unreachable(let host, let reason):
      return "\(host) cannot be reached: \(reason)"
    case .insecure(let host, _):
      return "\(host)'s certificate is not trusted; the page was not loaded."
    case .other(let reason):
      return "The page could not be loaded: \(reason)"
    }
  }
}

/// One tab of a session's web view, and the `WKWebView` that shows it (#69).
///
/// The web view belongs to this model, never to a view: the panel only puts it on screen, the way
/// a terminal's pane outlives the view that draws it (ADR 0008). Changing session reloads nothing.
/// A tab restored from a previous launch keeps its address and title and creates no web view until
/// it is shown or an agent reaches for it.
@MainActor
@Observable
public final class BrowserTabModel: NSObject, Identifiable {
  public let id: BrowserTabID
  public let openedBy: BrowserTab.Opener
  /// The ticket's tab: first, pinned, never closed.
  public let isPinnedTicket: Bool

  public private(set) var url: URL
  /// The address of the document the page actually holds: set when a navigation commits, and only
  /// then. What an agent may do is decided on it — `url` already names where a navigation is
  /// heading, while the page, its script and its cookies are still the previous site's.
  public private(set) var committedURL: URL?
  /// The HTTP status of the last response the page's own document came with; `nil` before one, and
  /// for what is not HTTP. How a ticket's page tells a missing ticket from a found one (#89).
  public private(set) var mainFrameStatus: Int?
  public private(set) var title: String
  public private(set) var isLoading = false
  public private(set) var progress: Double = 0
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var failure: BrowserLoadFailure?
  /// The web content process stopped: the page is gone until it is reloaded.
  public private(set) var hasCrashed = false
  /// The attempts made so far at a local server that is not up yet, and whether they go on.
  public private(set) var retryAttempt = 0
  public private(set) var isRetrying = false
  /// An agent is acting on this tab right now: the tab strip marks it.
  public internal(set) var isAgentActing = false
  public private(set) var console = BrowserConsole()

  /// Set when the web view exists: the page itself.
  public private(set) var webView: WKWebView?

  /// Told when the address or the title changed, so the session can be kept.
  @ObservationIgnored var didChange: (@MainActor () -> Void)?
  /// Asked when a page wants a new window, or the user a new tab (#186): it becomes a tab of the
  /// same session, after this one, in front or behind.
  @ObservationIgnored var openInNewTab: (@MainActor (URL, _ byAgent: Bool, _ activate: Bool) -> Void)?
  /// Given the web view WebKit made for a window a page opened — a sign-in pop-up — to show as a
  /// tab of the same session. It stays that page's opener's: the pop-up hands the sign-in back to
  /// it through `window.opener`, which a tab opened on the same address would not have.
  @ObservationIgnored var openPopup:
    (@MainActor (WKWebView, URL, _ byAgent: Bool, _ activate: Bool) -> Void)?
  /// The tab this one was opened from, while the user has not turned to another: the tabs it opens
  /// line up after it in the order they were opened, as in a browser (#186).
  @ObservationIgnored var openerID: BrowserTabID?
  /// Told when the page closes its own window, as a pop-up does once it is done.
  @ObservationIgnored var didCloseWindow: (@MainActor () -> Void)?
  /// Asked before a download or another application's address that an agent caused.
  @ObservationIgnored var confirmAgentEffect:
    (@MainActor (_ kind: BrowserAgentEffect, _ tab: BrowserTabModel) async -> Bool)?
  /// What the page does counts as the agent's doing: from the tab's opening by the agent, or the
  /// agent's first action on it, until the user clicks in the page or types into it (#241). A
  /// click the agent dispatches is no event of AppKit's and never hands the tab back. Kept between
  /// launches with the tab.
  @ObservationIgnored var isAgentDriven: Bool {
    didSet { if isAgentDriven != oldValue { didChange?() } }
  }
  /// The tab is a window a page of the agent's opened: its opener can still script it, so what it
  /// downloads or opens is asked even once the user has clicked in it (#241).
  let isOpenedByAgentPage: Bool
  /// The tab was closed: a download it started and nobody decided on yet is refused.
  @ObservationIgnored var isClosed = false
  /// Opens another application's address: macOS does, the tests only note it.
  // Opens outside: only called from the navigation policy below, whose every call says why it may
  // open there (#241).
  @ObservationIgnored var openApplicationAddress: @MainActor (URL) -> Void = { url in
    // Opens outside: see above — this is the one way the policy hands an address to macOS.
    NSWorkspace.shared.open(url)
  }

  @ObservationIgnored private let configuration: BrowserWebConfiguration
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  /// Local origins whose untrusted certificate the user accepted, for this tab's life.
  @ObservationIgnored private var acceptedInsecureHosts: Set<String> = []

  static let maximumRetries = 30
  static let retryInterval: Duration = .seconds(2)

  init(
    id: BrowserTabID = BrowserTabID(),
    url: URL,
    title: String = "",
    openedBy: BrowserTab.Opener,
    isAgentDriven: Bool? = nil,
    isOpenedByAgentPage: Bool = false,
    isPinnedTicket: Bool = false,
    configuration: BrowserWebConfiguration
  ) {
    self.id = id
    self.url = url
    self.title = title
    self.openedBy = openedBy
    self.isPinnedTicket = isPinnedTicket
    self.configuration = configuration
    self.isAgentDriven = (isAgentDriven ?? (openedBy == .agent)) || isOpenedByAgentPage
    self.isOpenedByAgentPage = isOpenedByAgentPage
    super.init()
  }

  /// What is kept of this tab.
  public var persisted: BrowserTab {
    BrowserTab(
      id: id, url: url, title: title, openedBy: openedBy, isAgentDriven: asksBeforeEffects)
  }

  public var isLoaded: Bool {
    webView != nil
  }

  /// What the tab strip shows: the title once there is one, else the host.
  public var displayTitle: String {
    if !title.isEmpty { return title }
    if url.isFileURL { return url.lastPathComponent }
    return BrowserOrigin(url: url)?.description ?? url.absoluteString
  }

  /// The site of the document the page holds, or `nil` while none has committed.
  public var committedOrigin: BrowserOrigin? {
    committedURL.flatMap(BrowserOrigin.init(url:))
  }

  public var origin: BrowserOrigin? {
    BrowserOrigin(url: url)
  }

  /// The user clicked in the page or typed into it: what it does next is theirs — except in a
  /// window a page of the agent's opened, which that page can still script.
  func userDidInteract() {
    isAgentDriven = false
  }

  /// A download or another application's address the page causes is asked.
  var asksBeforeEffects: Bool {
    isAgentDriven || isOpenedByAgentPage
  }

  // MARK: - Loading

  /// The web view, created and loaded on first use.
  @discardableResult
  public func ensureWebView() -> WKWebView {
    if let webView { return webView }
    let webView = configuration.makeWebView()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    configuration.attachConsole(to: webView, handler: ConsoleMessageHandler(tab: self))
    connectLinks(of: webView)
    self.webView = webView
    observe(webView)
    configuration.park(webView)
    load(url)
    return webView
  }

  /// Takes a web view WebKit already made, and is loading, for a pop-up.
  func adopt(_ webView: WKWebView) {
    webView.navigationDelegate = self
    webView.uiDelegate = self
    configuration.attachConsole(to: webView, handler: ConsoleMessageHandler(tab: self))
    if let webView = webView as? SessionWebView { connectLinks(of: webView) }
    self.webView = webView
    observe(webView)
    configuration.park(webView)
  }

  /// A three-finger tap on a link, and the menu of one, open a tab behind this one or the external
  /// browser (#186).
  private func connectLinks(of webView: SessionWebView) {
    configuration.attachHoveredLink(to: webView)
    webView.onUserInput = { [weak self] in self?.userDidInteract() }
    webView.openInBackgroundTab = { [weak self] url in
      self?.openInNewTab?(url, false, false)
    }
    webView.openExternally = { url in
      guard LinkRouting.isPage(url) else { return }
      ExternalOpening.open(url)
    }
  }

  public func load(_ url: URL) {
    stopRetrying()
    self.url = url
    failure = nil
    hasCrashed = false
    didChange?()
    guard let webView else { return }
    if url.isFileURL {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      webView.load(URLRequest(url: url))
    }
  }

  public func reload(ignoringCache: Bool = false) {
    guard let webView else {
      ensureWebView()
      return
    }
    stopRetrying()
    failure = nil
    if hasCrashed || webView.url == nil {
      hasCrashed = false
      load(url)
    } else if ignoringCache {
      webView.reloadFromOrigin()
    } else {
      webView.reload()
    }
  }

  public func stopLoading() {
    webView?.stopLoading()
  }

  public func goBack() {
    webView?.goBack()
  }

  public func goForward() {
    webView?.goForward()
  }

  public func stopRetrying() {
    retryAttempt = 0
    retryTask?.cancel()
    retryTask = nil
    isRetrying = false
  }

  /// "Continue Anyway" on a local server with a certificate of its own.
  public func acceptInsecureCertificate() {
    guard case .insecure(let host, true) = failure else { return }
    acceptedInsecureHosts.insert(host)
    reload()
  }

  /// Frees the page, keeping where it was: it loads again when it is next wanted.
  public func discard() {
    stopRetrying()
    observations = []
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.removeFromSuperview()
    webView = nil
    committedURL = nil
    mainFrameStatus = nil
    isLoading = false
  }

  /// Waits until the page has loaded or failed, within `timeout`. A page that is still loading then
  /// is reported as such rather than as a failure.
  public func waitUntilSettled(timeout: Duration = .seconds(15)) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    // The navigation may not have started yet when this is called.
    try? await Task.sleep(for: .milliseconds(50))
    while clock.now < deadline, isLoading || (webView?.isLoading ?? false) {
      try? await Task.sleep(for: .milliseconds(50))
    }
    await readTitle(before: deadline)
  }

  /// Asks the loaded page for its title. WebKit reports it after saying the load finished, and a
  /// busy Mac lets whatever waited on that read the tab in between, with the previous title or
  /// none. Given up on at `deadline`, for a page too busy to answer.
  private func readTitle(before deadline: ContinuousClock.Instant) async {
    guard let webView, !isLoading, !webView.isLoading, failure == nil, !hasCrashed else { return }
    let reading = TitleReading()
    let title = await withCheckedContinuation { continuation in
      reading.continuation = continuation
      reading.tasks = [
        Task {
          let title = try? await webView.evaluateJavaScript(
            "document.title", in: nil, contentWorld: .defaultClient)
          reading.finish(title as? String)
        },
        Task {
          try? await Task.sleep(until: deadline)
          reading.finish(nil)
        },
      ]
    }
    guard let title, !title.isEmpty, title != self.title else { return }
    self.title = title
    didChange?()
  }

  /// Where the document is now — which a single-page application changes without a navigation —
  /// and the titles it gives itself, in the order a ticket's title is looked for: `og:title`,
  /// `twitter:title`, then the document's title. Read together, from the same document. `nil`
  /// when the page cannot be asked.
  func readTitleMetadata() async -> (address: URL?, titles: [String])? {
    guard let webView, !hasCrashed else { return nil }
    let script = """
      (() => {
        const meta = (selector) => {
          const element = document.querySelector(selector);
          return element ? (element.getAttribute('content') || '') : '';
        };
        return [location.href, meta('meta[property="og:title"]'),
          meta('meta[name="twitter:title"]'), document.title || ''];
      })()
      """
    let value = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    guard let strings = (value as? [Any])?.map({ ($0 as? String) ?? "" }), !strings.isEmpty
    else { return nil }
    return (URL(string: strings[0]), Array(strings.dropFirst()))
  }

  private func observe(_ webView: WKWebView) {
    observations = [
      webView.observe(\.title, options: [.new]) { [weak self] view, _ in
        MainActor.assumeIsolated {
          guard let self, let title = view.title, !title.isEmpty, title != self.title else {
            return
          }
          self.title = title
          self.didChange?()
        }
      },
      webView.observe(\.url, options: [.new]) { [weak self] view, _ in
        MainActor.assumeIsolated {
          guard let self, let url = view.url, url != self.url, url.absoluteString != "about:blank"
          else { return }
          self.url = url
          self.didChange?()
        }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
        MainActor.assumeIsolated { self?.isLoading = view.isLoading }
      },
      webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
        MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
      },
      webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
        MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
      },
      webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
        MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
      },
    ]
  }

  fileprivate func record(console entry: BrowserConsoleEntry) {
    console.append(entry)
  }

  private func failed(_ error: any Error) {
    let error = error as NSError
    // A navigation replaced by another one, or turned into a download, is not a failure.
    if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
    if error.domain == WKError.errorDomain, error.code == 102 { return }
    let host = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? url.host ?? ""
    let origin = BrowserOrigin(url: url)
    let isLocal = origin?.isLocal ?? false
    let kind: BrowserLoadFailure
    switch (error.domain, error.code) {
    case (NSURLErrorDomain, NSURLErrorCannotConnectToHost) where isLocal:
      kind = .serverNotStarted(origin: origin?.description ?? host)
    case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
      kind = .offline(host: host)
    case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
      (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
      (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
      (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
      (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
      kind = .insecure(host: host, isLocal: isLocal)
    case (NSURLErrorDomain, NSURLErrorCannotFindHost),
      (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
      (NSURLErrorDomain, NSURLErrorTimedOut),
      (NSURLErrorDomain, NSURLErrorDNSLookupFailed),
      (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
      kind = .unreachable(host: host, reason: error.localizedDescription)
    default:
      kind = .other(reason: error.localizedDescription)
    }
    failure = kind
    isLoading = false
    console.append(
      BrowserConsoleEntry(
        level: .error, text: "Failed to load \(url.absoluteString): \(kind.agentDescription)"))
    if case .serverNotStarted = kind { scheduleRetry() }
  }

  /// A local server that is not up yet is tried again every two seconds, for a minute: the
  /// preview appears on its own once `npm run dev` is ready.
  private func scheduleRetry() {
    guard retryTask == nil, retryAttempt < Self.maximumRetries else {
      isRetrying = false
      return
    }
    isRetrying = true
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: Self.retryInterval)
      guard !Task.isCancelled, let self else { return }
      self.retryTask = nil
      self.retryAttempt += 1
      guard let webView = self.webView else { return }
      webView.load(URLRequest(url: self.url))
    }
  }
}

/// Whichever answers first of the page and the deadline.
@MainActor
private final class TitleReading {
  var continuation: CheckedContinuation<String?, Never>?
  var tasks: [Task<Void, Never>] = []

  func finish(_ title: String?) {
    continuation?.resume(returning: title)
    continuation = nil
    for task in tasks { task.cancel() }
  }
}

/// What an agent's action may cause that leaves the page: a file saved, another application opened.
public enum BrowserAgentEffect: Hashable, Sendable {
  case download(filename: String)
  case externalApplication(URL)
  /// Another application's address that reaches another computer — a share to mount, a remote
  /// screen or shell: asked whoever's the tab is, even after a click of the user's (#241).
  case networkAddress(URL)

  /// The schemes macOS hands to an application that connects to another computer: Finder mounts
  /// `smb:`, `afp:`, `nfs:`, `cifs:` and `ftp:` shares, Screen Sharing opens `vnc:`, Terminal
  /// `ssh:` and `telnet:`.
  static let networkSchemes: Set<String> = [
    "smb", "afp", "vnc", "nfs", "ftp", "ssh", "telnet", "cifs",
  ]

  static func reachesAnotherComputer(_ url: URL) -> Bool {
    networkSchemes.contains(url.scheme?.lowercased() ?? "")
  }
}

// MARK: - WebKit delegates

// Every navigation is allowed on purpose: the tab is a browser (ADR 0023). Top-level schemes are
// filtered below and by `BrowserActionPolicy`; what an agent does on a page is decided there.
extension BrowserTabModel: WKNavigationDelegate, WKUIDelegate {
  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)
  {
    failure = nil
    hasCrashed = false
  }

  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    committedURL = webView.url
    (webView as? SessionWebView)?.hoveredLink = nil
    console.reset()
    stopRetrying()
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoading = false
    failure = nil
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    failed(error)
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    failed(error)
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    hasCrashed = true
    isLoading = false
    console.append(
      BrowserConsoleEntry(level: .error, text: "The page's web content process stopped."))
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    preferences: WKWebpagePreferences
  ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
    guard let target = navigationAction.request.url, let scheme = target.scheme?.lowercased() else {
      return (.allow, preferences)
    }
    // ⌘-click, ⇧⌘-click and the middle button on a link: a new tab, as in a browser (#186). A link
    // meant for a new window reaches `createWebViewWith` instead, which decides the same way.
    // Only after a press of the user's with the same keys — a click the page's script dispatched
    // carries keys too — and to a file only from a file.
    if ["http", "https", "file"].contains(scheme), navigationAction.targetFrame != nil,
      case .newTab(let activate) = BrowserLinkGesture.decide(
        navigationAction, isAgentDriven: isAgentDriven),
      let sessionView = webView as? SessionWebView,
      sessionView.followsPress(
        with: navigationAction.modifierFlags, now: ProcessInfo.processInfo.systemUptime),
      BrowserLinkGesture.mayOpen(target, from: webView.url)
    {
      openInNewTab?(target, false, activate)
      return (.cancel, preferences)
    }
    if ["http", "https", "file", "about", "blob", "data"].contains(scheme) {
      // `data:` and `blob:` are refused as a top-level destination by the agent's tools, but a
      // page may use them for its own frames and downloads. A `download` link is a download,
      // decided with every other one.
      return (navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }
    // Another application's address. One that reaches another computer — a share to mount, a
    // remote screen — is always asked. Any other is asked when the tab is the agent's, and opened
    // otherwise only after a click of the user's: a click the page's script dispatches is
    // `.linkActivated` too, and must not open an application unasked (#241).
    if BrowserAgentEffect.reachesAnotherComputer(target) {
      let allowed = await confirmAgentEffect?(.networkAddress(target), self) ?? false
      // Opens outside: the user allowed this address in the question just answered.
      if allowed { openApplicationAddress(target) }
    } else if asksBeforeEffects {
      let allowed = await confirmAgentEffect?(.externalApplication(target), self) ?? false
      // Opens outside: the user allowed this address in the question just answered.
      if allowed { openApplicationAddress(target) }
    } else if navigationAction.navigationType == .linkActivated,
      let sessionView = webView as? SessionWebView,
      sessionView.followsPress(
        with: navigationAction.modifierFlags, now: ProcessInfo.processInfo.systemUptime)
    {
      // Unsafe open, to fix in #289: a click of the user's in the page opens, without a
      // question, whatever application address the page's script sends within the second — no
      // other computer, but any application that registered a scheme.
      openApplicationAddress(target)
    } else {
      record(
        console: BrowserConsoleEntry(
          level: .warn, text: "Blocked opening \(scheme): not a click of the user's."))
    }
    return (.cancel, preferences)
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
  ) async -> WKNavigationResponsePolicy {
    if navigationResponse.isForMainFrame {
      mainFrameStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
    }
    // Whether a download is the agent's doing is decided once, where its destination is: every way
    // a download starts — this response, a `download` link, a `blob:` — ends up there (#241).
    return navigationResponse.canShowMIMEType ? .allow : .download
  }

  public func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    BrowserDownloads.shared.track(download, from: self, page: webView.url)
  }

  public func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    BrowserDownloads.shared.track(download, from: self, page: webView.url)
  }

  public func webView(
    _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let space = challenge.protectionSpace
    if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      acceptedInsecureHosts.contains(space.host), let trust = space.serverTrust
    {
      return (.useCredential, URLCredential(trust: trust))
    }
    return (.performDefaultHandling, nil)
  }

  /// `target="_blank"` and `window.open`: a tab of the same session, never a window of its own.
  public func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    let target = navigationAction.request.url ?? URL(string: "about:blank")!
    // A window a page opens comes to the front, unless the user ⌘-clicked the link that opens it.
    let activate: Bool
    if case .newTab(let inFront) = BrowserLinkGesture.decide(
      navigationAction, isAgentDriven: isAgentDriven)
    {
      activate = inFront
    } else {
      activate = true
    }
    guard let openPopup else {
      openInNewTab?(target, asksBeforeEffects, activate)
      return nil
    }
    // WebKit must be handed a view made with the configuration it gives: that is what ties the
    // pop-up to its opener. Its scripts are its own, so that its console reaches its own tab.
    configuration.userContentController = self.configuration.makeContentController()
    let popup = SessionWebView(frame: webView.bounds, configuration: configuration)
    popup.allowsBackForwardNavigationGestures = true
    popup.allowsMagnification = true
    openPopup(popup, target, asksBeforeEffects, activate)
    return popup
  }

  public func webViewDidClose(_ webView: WKWebView) {
    didCloseWindow?()
  }
}

/// Where downloads go, and whether they may: the Downloads folder, under a name that does not
/// overwrite anything, once asked when the tab is the agent's; every file then carries macOS's
/// quarantine, with where it came from (#241).
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate {
  static let shared = BrowserDownloads()

  private struct Tracked {
    /// Kept so that its identity is not given to another download while this one is listed.
    let download: WKDownload
    weak var tab: BrowserTabModel?
    /// Decided when the download starts, not when its answer arrives: the server chooses when
    /// that is, and the tab may be closed or taken back meanwhile.
    let asks: Bool
    let page: URL?
    var destination: URL?
  }

  /// Where files are saved: the user's Downloads folder, another one in tests.
  var folder: @MainActor () -> URL = {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
  }
  /// The downloads under way, by identity: a `WKDownload` holds its delegate weakly, this object
  /// is what keeps the tab and the page each one came from.
  private var tracked: [ObjectIdentifier: Tracked] = [:]

  /// How many downloads are started and not yet saved, refused or failed.
  var underWay: Int { tracked.count }

  func track(_ download: WKDownload, from tab: BrowserTabModel, page: URL?) {
    tracked[ObjectIdentifier(download)] = Tracked(
      download: download, tab: tab, asks: tab.asksBeforeEffects, page: page)
    download.delegate = self
  }

  private func entry(for download: WKDownload) -> Tracked? {
    guard let entry = tracked[ObjectIdentifier(download)], entry.download === download else {
      return nil
    }
    return entry
  }

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
  ) async -> URL? {
    let key = ObjectIdentifier(download)
    let name = Self.safeName(suggestedFilename)
    guard let entry = entry(for: download) else { return nil }
    if entry.asks {
      // A tab closed before the answer arrived cannot show the question: the download is refused.
      guard let tab = entry.tab, !tab.isClosed, let confirm = tab.confirmAgentEffect,
        await confirm(.download(filename: name), tab), !tab.isClosed
      else {
        tracked[key] = nil
        return nil
      }
    }
    let destination = Self.freeName(for: name, in: folder())
    tracked[key]?.destination = destination
    return destination
  }

  func downloadDidFinish(_ download: WKDownload) {
    guard let done = entry(for: download) else { return }
    tracked[ObjectIdentifier(download)] = nil
    guard let destination = done.destination else { return }
    do {
      try Self.quarantine(destination, from: download.originalRequest?.url, page: done.page)
    } catch {
      done.tab?.record(
        console: BrowserConsoleEntry(
          level: .warn,
          text: "Could not mark \(destination.lastPathComponent) as downloaded: \(error)"))
    }
  }

  func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
    if entry(for: download) != nil { tracked[ObjectIdentifier(download)] = nil }
  }

  /// The name a page suggests, without what would make it read as another — a right-to-left
  /// override shows `fdp.command` as `dnammoc.pdf` — nor control characters or a folder.
  static func safeName(_ suggested: String) -> String {
    let hidden: Set<Unicode.Scalar> = [
      "\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
      "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]
    var scalars = String.UnicodeScalarView()
    for scalar in suggested.unicodeScalars
    where !hidden.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar) {
      scalars.append(scalar)
    }
    let name = (String(scalars) as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? "download" : name
  }

  static func freeName(for name: String, in folder: URL) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = folder.appendingPathComponent(name)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
      candidate = folder.appendingPathComponent(numbered)
      index += 1
    }
    return candidate
  }

  /// What the quarantine says of a file: a web download, by this application, from that address
  /// and page — when they are ones a person could open again. A `data:` address is the file
  /// itself, possibly megabytes, and a `blob:` one means nothing once the page is gone.
  static func quarantineProperties(address: URL?, page: URL?) -> [String: Any] {
    var properties: [String: Any] = [
      kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
      kLSQuarantineAgentNameKey as String: "Vibe Manager",
    ]
    func kept(_ url: URL?) -> URL? {
      guard let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
        return nil
      }
      return url
    }
    if let address = kept(address) { properties[kLSQuarantineDataURLKey as String] = address }
    if let page = kept(page) { properties[kLSQuarantineOriginURLKey as String] = page }
    return properties
  }

  /// Marks a file as downloaded from the web: Gatekeeper checks it before it is opened, and names
  /// where it came from. WebKit marks it too, without saying where from; this does not rely on it.
  static func quarantine(_ file: URL, from address: URL?, page: URL?) throws {
    var values = URLResourceValues()
    values.quarantineProperties = quarantineProperties(address: address, page: page)
    var file = file
    try file.setResourceValues(values)
  }
}

/// Receives the console lines the page script posts.
private final class ConsoleMessageHandler: NSObject, WKScriptMessageHandler {
  weak var tab: BrowserTabModel?

  init(tab: BrowserTabModel) {
    self.tab = tab
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any], let text = body["text"] as? String else {
      return
    }
    let level = (body["level"] as? String).flatMap(BrowserConsoleEntry.Level.init) ?? .log
    MainActor.assumeIsolated {
      tab?.record(console: BrowserConsoleEntry(level: level, text: text))
    }
  }
}

// MARK: - Console

public struct BrowserConsoleEntry: Hashable, Sendable {
  public enum Level: String, Sendable, CaseIterable, Comparable {
    case debug, log, info, warn, error

    public static func < (lhs: Self, rhs: Self) -> Bool {
      allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
  }

  public let date: Date
  public let level: Level
  public let text: String

  public init(date: Date = Date(), level: Level, text: String) {
    self.date = date
    self.level = level
    self.text = text
  }
}

/// The last messages of a page's console, bounded.
public struct BrowserConsole: Hashable, Sendable {
  public static let capacity = 500
  public private(set) var entries: [BrowserConsoleEntry] = []

  public init() {
    // An empty console.
  }

  mutating func append(_ entry: BrowserConsoleEntry) {
    entries.append(entry)
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
  }

  /// A new document starts a new console; what the previous one said about failing to load stays,
  /// since that is the story of this load.
  mutating func reset() {
    entries.removeAll { !$0.text.hasPrefix("Failed to load ") }
  }
}
