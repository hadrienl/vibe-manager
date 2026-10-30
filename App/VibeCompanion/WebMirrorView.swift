import CompanionCore
import OSLog
import SwiftUI
import WebKit

/// A session's web view, kept in step with the Mac's (#400): the same page, in a web view of the
/// phone's own — scrolled at once under the finger — and whatever either side's user does there,
/// the other does too: the address, the tab, the scroll.
///
/// A page of the Mac's own (`localhost:4000`, its local network) is loaded through the Mac, which
/// makes each request for the phone; any other loads as in Safari.
struct WebMirrorView: View {
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @State private var address = ""
  @FocusState private var addressFocused: Bool
  /// The last address typed here, loaded by the phone itself; its number tells each apart.
  @State private var typed: (number: Int, url: URL)?
  /// The phone's own web view, as the bars around it show it.
  @State private var page = MirroredPage()

  private var state: RemoteWebState? {
    channel.webState?.sessionID == sessionID ? channel.webState : nil
  }
  private var activeTab: RemoteWebTab? {
    state?.tabs.first { $0.id == state?.activeTabID }
  }

  var body: some View {
    VStack(spacing: 0) {
      addressBar
      if let tab = activeTab, let url = URL(string: tab.url) {
        SyncedWebView(
          url: url, isMacLoading: tab.isLoading, typed: typed, scroll: state?.scroll ?? 0,
          channel: channel, page: page,
          navigated: { channel.web(.navigate($0.absoluteString), in: sessionID) },
          scrolled: { channel.web(.scrollTo($0), in: sessionID) })
      } else if state != nil {
        ContentUnavailableView {
          Label("No Page", systemImage: "globe")
        } description: {
          Text("Type an address to open a page, here and on the Mac.")
        }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("Web View")
    .navigationSubtitle(page.isDetached ? Text("Not Synced") : Text("In sync with the Mac"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("Tabs", systemImage: "square.on.square") {
          ForEach(state?.tabs ?? []) { tab in
            Button {
              page.attach()
              channel.web(.selectTab(tab.id), in: sessionID)
            } label: {
              if tab.id == state?.activeTabID {
                Label(tab.title.isEmpty ? tab.url : tab.title, systemImage: "checkmark")
              } else {
                Text(verbatim: tab.title.isEmpty ? tab.url : tab.title)
              }
            }
          }
        }
        .disabled((state?.tabs.count ?? 0) < 2)
      }
      ToolbarItemGroup(placement: .bottomBar) {
        Button("Back", systemImage: "chevron.backward") {
          if page.isDetached { page.webView?.goBack() } else { channel.web(.back, in: sessionID) }
        }
        .disabled(page.isDetached ? !page.canGoBack : state?.canGoBack != true)
        Button("Forward", systemImage: "chevron.forward") {
          if page.isDetached {
            page.webView?.goForward()
          } else {
            channel.web(.forward, in: sessionID)
          }
        }
        .disabled(page.isDetached ? !page.canGoForward : state?.canGoForward != true)
        Spacer()
        Button("Open in Safari", systemImage: "safari") {
          if let safariURL { UIApplication.shared.open(safariURL) }
        }
        .disabled(safariURL == nil)
        if !page.isDetached {
          Button("Stop Syncing", systemImage: "link.badge.minus") { page.detach() }
            .disabled(activeTab == nil)
        }
        Button("Reload", systemImage: "arrow.clockwise") {
          if page.isDetached {
            page.webView?.reload()
          } else {
            channel.web(.reload, in: sessionID)
            channel.reloadWeb += 1
          }
        }
      }
    }
    .onAppear { channel.showWeb(sessionID) }
    .onDisappear { channel.showWeb(nil) }
    .onChange(of: activeTab?.url, initial: true) { _, url in
      if !addressFocused { address = url ?? "" }
    }
  }

  /// The page shown, for Safari — or the app its address opens, such as GitHub's. Not a page of
  /// the Mac's own, which only the Mac reaches.
  private var safariURL: URL? {
    guard let url = page.url,
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      !RemoteWebAddress.isMacLocal(url)
    else { return nil }
    return url
  }

  private var addressBar: some View {
    HStack(spacing: 8) {
      Image(systemName: activeTab?.isLoading == true ? "hourglass" : "globe")
        .foregroundStyle(.secondary)
      TextField("Address", text: $address)
        .focused($addressFocused)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit {
          switch RemoteWebAddress.typed(address, pageOpen: activeTab != nil) {
          case .load(let url): typed = (number: (typed?.number ?? 0) + 1, url: url)
          case .tellMac(let url): channel.web(.navigate(url.absoluteString), in: sessionID)
          case nil: break
          }
        }
      if page.isDetached {
        Button {
          page.attach()
        } label: {
          Label("Not Synced", systemImage: "personalhotspot.slash")
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .accessibilityHint("Follows the Mac again")
      } else if let count = state?.tabs.count, count > 1,
        let index = state?.tabs.firstIndex(where: { $0.id == state?.activeTabID })
      {
        Text("\(index + 1) of \(count)").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .glassEffect(.regular.interactive(), in: Capsule())
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

/// The phone's web view as the bars around it show it: its page, and whether it is detached from
/// the Mac (#456).
@MainActor @Observable
private final class MirroredPage {
  fileprivate(set) var isDetached = false
  fileprivate(set) var url: URL?
  fileprivate(set) var canGoBack = false
  fileprivate(set) var canGoForward = false
  /// Kept here, not in the web view's coordinator, for a web view made anew — the channel back
  /// after a break — not to take an address typed before for a new one.
  @ObservationIgnored fileprivate var follower = RemoteWebFollower()
  @ObservationIgnored fileprivate weak var webView: WKWebView?
  @ObservationIgnored fileprivate weak var coordinator: SyncedWebView.Coordinator?

  func detach() { coordinator?.detach(byUser: true) }
  func attach() { coordinator?.attach() }
}

/// The phone's web view: it loads what the Mac shows, and says what its user does.
private struct SyncedWebView: UIViewRepresentable {
  let url: URL
  let isMacLoading: Bool
  let typed: (number: Int, url: URL)?
  let scroll: Double
  let channel: RemoteChannel
  let page: MirroredPage
  let navigated: (URL) -> Void
  let scrolled: (Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    // Any page an agent opened on the Mac, so no list of app-bound domains: the navigation
    // delegate below keeps it to the web and the Mac's own pages.
    let configuration = WKWebViewConfiguration()  // NOSONAR
    let handler = MacSchemeHandler(channel: channel)
    for scheme in ["http", "https"] {
      configuration.setURLSchemeHandler(
        handler, forURLScheme: RemoteWebAddress.proxiedPrefix + scheme)
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)  // NOSONAR
    webView.allowsBackForwardNavigationGestures = false
    webView.navigationDelegate = context.coordinator
    context.coordinator.observe(webView, for: page)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.navigated = navigated
    coordinator.scrolled = scrolled
    if let typed, page.follower.takeTyped(typed.number) {
      coordinator.load(typed.url, in: webView, byUser: true)
    }
    coordinator.show(url, isLoading: isMacLoading, in: webView)
    coordinator.scroll(to: scroll, in: webView)
    if coordinator.reloads != channel.reloadWeb {
      coordinator.reloads = channel.reloadWeb
      webView.reload()
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    /// The pages the web view goes to: the web, and the Mac's own through the channel. Anything
    /// else — a file, another application's scheme — is not opened from here.
    static let allowedSchemes: Set<String> = [
      "http", "https", "about", "blob", "data",
      RemoteWebAddress.proxiedPrefix + "http", RemoteWebAddress.proxiedPrefix + "https",
    ]

    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      let scheme = action.request.url?.scheme?.lowercased() ?? ""
      guard Self.allowedSchemes.contains(scheme) else { return decisionHandler(.cancel) }
      if action.targetFrame?.isMainFrame == true {
        // A server's redirect is an `.other` navigation, as a script's is.
        let navigation: RemoteWebFollower.Navigation =
          if loadingTyped || action.navigationType == .linkActivated {
            .user
          } else if [.formSubmitted, .formResubmitted, .other].contains(action.navigationType) {
            .redirect
          } else {
            .page
          }
        let source = loadingMac ? "from the Mac" : String(describing: navigation)
        loadingTyped = false
        loadingMac = false
        let wasDetached = follower.isDetached
        follower.phoneWillNavigate(
          navigation, to: action.request.url.map(RemoteWebAddress.unproxied))
        Self.logger.debug(
          "phone goes to \(action.request.url?.absoluteString ?? "-", privacy: .public) (\(source, privacy: .public))\(wasDetached == self.follower.isDetached ? "" : self.follower.isDetached ? ": detached" : ": attached", privacy: .public)"
        )
        publish()
      }
      decisionHandler(.allow)
    }

    func webView(
      _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!
    ) {
      current = navigation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      stoppedLoading(navigation, in: webView)
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
      stoppedLoading(navigation, in: webView)
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      stoppedLoading(navigation, in: webView)
    }

    /// The phone's loading ended: the Mac's page, if it moved meanwhile, is loaded now. Not when
    /// what ended is a navigation another one replaced — cancelled, -999 — which leaves that other
    /// one loading.
    private func stoppedLoading(_ navigation: WKNavigation?, in webView: WKWebView) {
      publish()
      guard navigation == nil || navigation === current else {
        Self.logger.debug("phone: a replaced navigation ended, ignored")
        return
      }
      current = nil
      if let address = follower.phoneStoppedLoading(), let url = URL(string: address) {
        Self.logger.debug(
          "phone loads the Mac's \(address, privacy: .public), held while it loaded")
        load(url, in: webView, byUser: false)
      }
    }

    static let logger = Logger(subsystem: "eu.hadrien.VibeManager.companion", category: "web")
    var navigated: (URL) -> Void = { _ in /* Set by the view. */ }
    private weak var page: MirroredPage?
    private weak var webView: WKWebView?
    /// The navigation under way, the one whose end ends the loading.
    private var current: WKNavigation?
    private var follower: RemoteWebFollower {
      get { page?.follower ?? RemoteWebFollower() }
      set { page?.follower = newValue }
    }
    /// Whether the load under way is of an address typed here, or of the Mac's page.
    private var loadingTyped = false
    private var loadingMac = false
    var scrolled: (Double) -> Void = { _ in /* Set by the view. */ }
    var reloads = 0
    private var observations: [NSKeyValueObservation] = []
    /// Until when a scroll is the Mac's, applied here, and not to be told back.
    private var quietUntil = Date.distantPast
    private var lastSentScroll: Double?
    private var pendingScroll: DispatchWorkItem?

    func observe(_ webView: WKWebView, for page: MirroredPage) {
      self.page = page
      self.webView = webView
      page.webView = webView
      page.coordinator = self
      page.follower.webViewReplaced()
      publish()
      observations.append(
        webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
          MainActor.assumeIsolated {
            guard let self, let url = webView.url else { return }
            let address = RemoteWebAddress.unproxied(url)
            self.publish()
            if let told = self.follower.phoneMoved(to: address.absoluteString),
              let toldURL = URL(string: told)
            {
              Self.logger.debug("phone tells the Mac \(told, privacy: .public)")
              self.navigated(toldURL)
            }
          }
        })
      observations.append(
        webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
          MainActor.assumeIsolated { self?.userScrolled(scrollView) }
        })
    }

    /// The Mac's page, loaded unless the phone is there already, its user went elsewhere, or it is
    /// still loading a page of its own.
    func show(_ url: URL, isLoading: Bool, in webView: WKWebView) {
      let before = follower.macURL
      let address = follower.macShows(url.absoluteString, isLoading: isLoading)
      if address != nil || before != follower.macURL {
        Self.logger.debug(
          "Mac shows \(url.absoluteString, privacy: .public)\(isLoading ? " (loading)" : "", privacy: .public): \(address == nil ? (self.follower.isDetached ? "detached, not followed" : "not followed") : "followed", privacy: .public)"
        )
      }
      guard let address, let target = URL(string: address) else { return }
      load(target, in: webView, byUser: false)
    }

    func detach(byUser: Bool) {
      follower.detach(byUser: byUser)
      Self.logger.debug("phone detached\(byUser ? " by its user" : "", privacy: .public)")
      publish()
    }

    /// Follows the Mac again from its next move; nothing loads now.
    func attach() {
      follower.attach()
      Self.logger.debug("phone attached by its user")
      publish()
    }

    /// What the bars show of the phone's web view.
    private func publish() {
      guard let page, let webView else { return }
      page.isDetached = follower.isDetached
      page.url = webView.url.map(RemoteWebAddress.unproxied)
      page.canGoBack = webView.canGoBack
      page.canGoForward = webView.canGoForward
    }

    func load(_ url: URL, in webView: WKWebView, byUser: Bool) {
      loadingTyped = byUser
      loadingMac = !byUser
      webView.load(URLRequest(url: RemoteWebAddress.proxied(url)))
    }

    /// Where the Mac's user scrolled, unless that is where the phone already is.
    func scroll(to fraction: Double, in webView: WKWebView) {
      let scrollView = webView.scrollView
      let range = scrollView.contentSize.height - scrollView.bounds.height
      guard !follower.isDetached, range > 0, abs(Self.fraction(of: scrollView) - fraction) > 0.005,
        lastSentScroll.map({ abs($0 - fraction) > 0.005 }) ?? true
      else { return }
      quietUntil = Date().addingTimeInterval(0.4)
      scrollView.setContentOffset(
        CGPoint(x: scrollView.contentOffset.x, y: fraction * range), animated: false)
    }

    /// The phone's user scrolled: told to the Mac, at most every tenth of a second.
    private func userScrolled(_ scrollView: UIScrollView) {
      guard !follower.isDetached, Date() > quietUntil,
        scrollView.isTracking || scrollView.isDecelerating
      else {
        return
      }
      pendingScroll?.cancel()
      let work = DispatchWorkItem { [weak self, weak scrollView] in
        guard let self, let scrollView else { return }
        let fraction = Self.fraction(of: scrollView)
        self.lastSentScroll = fraction
        self.scrolled(fraction)
      }
      pendingScroll = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    static func fraction(of scrollView: UIScrollView) -> Double {
      let range = scrollView.contentSize.height - scrollView.bounds.height
      guard range > 0 else { return 0 }
      return min(1, max(0, scrollView.contentOffset.y / range))
    }
  }
}

/// Hands the web view's requests for the Mac's own pages to the channel, which has the Mac make
/// them.
private final class MacSchemeHandler: NSObject, WKURLSchemeHandler {
  private let channel: RemoteChannel
  /// The tasks WebKit stopped: answering one of them would raise.
  private var stopped: Set<ObjectIdentifier> = []

  init(channel: RemoteChannel) {
    self.channel = channel
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    let request = task.request
    guard let url = request.url else { return }
    let key = ObjectIdentifier(task)
    var headers = request.allHTTPHeaderFields ?? [:]
    headers["Accept-Encoding"] = nil
    let body = request.httpBody
    Task { @MainActor in
      let response = await channel.fetch(
        url: RemoteWebAddress.unproxied(url), method: request.httpMethod ?? "GET",
        headers: headers, body: body)
      guard !stopped.contains(key) else { return }
      if let failure = response.failure {
        task.didFailWithError(
          NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: failure]))
        return
      }
      let http = HTTPURLResponse(
        url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
        headerFields: response.headers)
      if let http { task.didReceive(http) }
      task.didReceive(response.body)
      task.didFinish()
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    stopped.insert(ObjectIdentifier(task))
  }
}
