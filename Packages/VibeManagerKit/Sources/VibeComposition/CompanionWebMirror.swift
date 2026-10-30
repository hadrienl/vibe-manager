import AppKit
import CompanionCore
import Foundation
import VibeBrowser
import VibeDomain
import VibeUI
import WebKit

/// A session's web view, kept in step with the phone's (#400). The phone shows the same page in a
/// web view of its own — its scrolling its own, at once — and each side tells the other what its
/// user does: the address, the tab, how far down the page is.
///
/// The Mac sends its tabs and its scroll whenever they change; it takes the phone's the same way.
/// A change one side just received is not sent back to it: neither side echoes the other.
@MainActor
final class CompanionWebMirror {
  /// How often the Mac's web view is read while the phone shows it.
  private static let interval: Duration = .milliseconds(400)
  /// How long after the phone scrolled the Mac's own scroll is taken for that one, not sent back.
  private static let echoWindow: Duration = .milliseconds(900)
  /// A scroll smaller than this is no scroll to tell.
  private static let scrollStep = 0.004

  let sessionID: SessionID
  private weak var appModel: AppModel?
  private let send: @MainActor (RemoteMessage) -> Void
  private var loop: Task<Void, Never>?
  private var lastState: RemoteWebState?
  private var phoneScrolledAt: ContinuousClock.Instant?

  init(
    sessionID: SessionID, appModel: AppModel, send: @escaping @MainActor (RemoteMessage) -> Void
  ) {
    self.sessionID = sessionID
    self.appModel = appModel
    self.send = send
  }

  func start() {
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  private var browser: SessionBrowser? {
    appModel?.browser?.browser(for: sessionID)
  }

  private func tick() async {
    guard let browser else { return }
    let active = browser.activeTab
    var scroll = lastState?.scroll ?? 0
    let isEcho = phoneScrolledAt.map { ContinuousClock.now - $0 < Self.echoWindow } ?? false
    if !isEcho, let webView = active?.webView, let fraction = await Self.scroll(of: webView) {
      scroll = fraction
    }
    let state = RemoteWebState(
      sessionID: sessionID.rawValue.uuidString,
      tabs: browser.tabs.map {
        RemoteWebTab(
          id: $0.id.rawValue.uuidString, title: $0.title, url: $0.url.absoluteString,
          isLoading: $0.isLoading)
      },
      activeTabID: active?.id.rawValue.uuidString, canGoBack: active?.canGoBack ?? false,
      canGoForward: active?.canGoForward ?? false, scroll: scroll)
    guard let last = lastState else {
      lastState = state
      send(.webState(state))
      return
    }
    var unscrolled = state
    unscrolled.scroll = last.scroll
    let moved = abs(state.scroll - last.scroll) >= Self.scrollStep
    guard unscrolled != last || moved else { return }
    lastState = state
    send(.webState(state))
  }

  /// How far down the page is, 0 at its top and 1 at its end.
  private static func scroll(of webView: WKWebView) async -> Double? {
    let script = """
      (() => {
        const range = document.documentElement.scrollHeight - window.innerHeight;
        return range > 0 ? window.scrollY / range : 0;
      })()
      """
    return (try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient))
      as? Double
  }

  // MARK: - What the phone does

  func perform(_ action: RemoteWebAction) async {
    guard let workspace = appModel?.browser, let browser else { return }
    let tab = browser.activeTab
    switch action {
    case .scrollTo(let fraction):
      phoneScrolledAt = .now
      lastState?.scroll = fraction
      let script = """
        window.scrollTo({top: \(fraction) * (document.documentElement.scrollHeight - window.innerHeight), behavior: 'instant'})
        """
      _ = try? await tab?.webView?.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    case .navigate(let address):
      guard let url = Self.url(from: address) else { return }
      if let tab {
        // The phone is already there: told back, it would load the page a second time.
        guard !RemoteWebAddress.same(tab.url.absoluteString, url.absoluteString) else { return }
        tab.load(url)
      } else {
        _ = workspace.open(url, in: sessionID, openedBy: .user)
      }
    case .back: tab?.goBack()
    case .forward: tab?.goForward()
    case .reload: tab?.reload()
    case .selectTab(let id):
      guard let uuid = UUID(uuidString: id) else { return }
      browser.activate(BrowserTabID(rawValue: uuid))
    }
  }

  /// What was typed in the address field: an address with its scheme, `localhost:4000` or a
  /// host, as Safari takes them.
  static func url(from address: String) -> URL? {
    RemoteWebAddress.typed(address)
  }

  // MARK: - The phone's requests

  /// A request of the phone's web view for a page of the Mac's own: made here, the answer sent
  /// back whole. Only to the Mac itself or its local network, never anywhere a phone could reach
  /// on its own.
  static func fetch(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
    guard let url = URL(string: request.url), RemoteWebAddress.isMacLocal(url) else {
      return RemoteHTTPResponse(
        id: request.id, status: 0, headers: [:], body: Data(), failure: "Adresse refusée")
    }
    var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers where !ignoredHeaders.contains(name.lowercased()) {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      let http = response as? HTTPURLResponse
      var headers: [String: String] = [:]
      for (name, value) in http?.allHeaderFields ?? [:] {
        guard let name = name as? String, let value = value as? String,
          !ignoredHeaders.contains(name.lowercased())
        else { continue }
        headers[name] = value
      }
      return RemoteHTTPResponse(
        id: request.id, status: http?.statusCode ?? 200, headers: headers, body: data)
    } catch {
      return RemoteHTTPResponse(
        id: request.id, status: 0, headers: [:], body: Data(),
        failure: error.localizedDescription)
    }
  }

  /// What the transport sets itself, or what no longer holds once the body is whole.
  private static let ignoredHeaders: Set<String> = [
    "host", "content-length", "connection", "transfer-encoding", "content-encoding",
    "accept-encoding",
  ]
}
