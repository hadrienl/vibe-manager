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
  /// Asked when a page wants a new window: it becomes a tab of the same session.
  @ObservationIgnored var openInNewTab: (@MainActor (URL, _ byAgent: Bool) -> Void)?
  /// Asked before a download or another application's address that an agent caused.
  @ObservationIgnored var confirmAgentEffect:
    (@MainActor (_ kind: BrowserAgentEffect, _ tab: BrowserTabModel) async -> Bool)?
  /// Until when what the page does counts as the agent's doing: set by each of its actions.
  @ObservationIgnored var agentDrivenUntil: Date = .distantPast

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
    isPinnedTicket: Bool = false,
    configuration: BrowserWebConfiguration
  ) {
    self.id = id
    self.url = url
    self.title = title
    self.openedBy = openedBy
    self.isPinnedTicket = isPinnedTicket
    self.configuration = configuration
    super.init()
  }

  /// What is kept of this tab.
  public var persisted: BrowserTab {
    BrowserTab(id: id, url: url, title: title, openedBy: openedBy)
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

  public var origin: BrowserOrigin? {
    BrowserOrigin(url: url)
  }

  var isAgentDriven: Bool {
    Date() < agentDrivenUntil
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
    self.webView = webView
    observe(webView)
    configuration.park(webView)
    load(url)
    return webView
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

/// What an agent's action may cause that leaves the page: a file saved, another application opened.
public enum BrowserAgentEffect: Hashable, Sendable {
  case download(filename: String)
  case externalApplication(URL)
}

// MARK: - WebKit delegates

extension BrowserTabModel: WKNavigationDelegate, WKUIDelegate {
  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)
  {
    failure = nil
    hasCrashed = false
  }

  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    console.reset()
    retryAttempt = 0
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
    if ["http", "https", "file", "about", "blob", "data"].contains(scheme) {
      // `data:` and `blob:` are refused as a top-level destination by the agent's tools, but a
      // page may use them for its own frames and downloads.
      return (.allow, preferences)
    }
    // Another application's address: opened by macOS, and only once asked when the agent did it.
    if isAgentDriven {
      let allowed = await confirmAgentEffect?(.externalApplication(target), self) ?? false
      if allowed { NSWorkspace.shared.open(target) }
    } else if navigationAction.navigationType == .linkActivated {
      NSWorkspace.shared.open(target)
    }
    return (.cancel, preferences)
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
  ) async -> WKNavigationResponsePolicy {
    guard navigationResponse.canShowMIMEType else {
      if isAgentDriven {
        let name = navigationResponse.response.suggestedFilename ?? "download"
        let allowed = await confirmAgentEffect?(.download(filename: name), self) ?? false
        return allowed ? .download : .cancel
      }
      return .download
    }
    return .allow
  }

  public func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    download.delegate = BrowserDownloads.shared
  }

  public func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    download.delegate = BrowserDownloads.shared
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
    if let target = navigationAction.request.url {
      openInNewTab?(target, isAgentDriven)
    }
    return nil
  }
}

/// Where downloads go: the Downloads folder, under a name that does not overwrite anything.
final class BrowserDownloads: NSObject, WKDownloadDelegate, @unchecked Sendable {
  static let shared = BrowserDownloads()

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
  ) async -> URL? {
    let folder =
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let name = (suggestedFilename as NSString).lastPathComponent
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = folder.appendingPathComponent(name.isEmpty ? "download" : name)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
      candidate = folder.appendingPathComponent(numbered)
      index += 1
    }
    return candidate
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

  public init() {}

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
