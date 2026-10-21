import CompanionCore
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
          url: url, scroll: state?.scroll ?? 0, channel: channel,
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
    .navigationSubtitle("In sync with the Mac")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("Tabs", systemImage: "square.on.square") {
          ForEach(state?.tabs ?? []) { tab in
            Button {
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
          channel.web(.back, in: sessionID)
        }
        .disabled(state?.canGoBack != true)
        Button("Forward", systemImage: "chevron.forward") {
          channel.web(.forward, in: sessionID)
        }
        .disabled(state?.canGoForward != true)
        Spacer()
        Button("Reload", systemImage: "arrow.clockwise") {
          channel.web(.reload, in: sessionID)
          channel.reloadWeb += 1
        }
      }
    }
    .onAppear { channel.showWeb(sessionID) }
    .onDisappear { channel.showWeb(nil) }
    .onChange(of: activeTab?.url, initial: true) { _, url in
      if !addressFocused { address = url ?? "" }
    }
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
        .onSubmit { channel.web(.navigate(address), in: sessionID) }
      if let count = state?.tabs.count, count > 1,
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

/// The phone's web view: it loads what the Mac shows, and says what its user does.
private struct SyncedWebView: UIViewRepresentable {
  let url: URL
  let scroll: Double
  let channel: RemoteChannel
  let navigated: (URL) -> Void
  let scrolled: (Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let handler = MacSchemeHandler(channel: channel)
    for scheme in ["http", "https"] {
      configuration.setURLSchemeHandler(
        handler, forURLScheme: RemoteWebAddress.proxiedPrefix + scheme)
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = false
    webView.navigationDelegate = context.coordinator
    context.coordinator.attach(webView)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.navigated = navigated
    coordinator.scrolled = scrolled
    coordinator.show(url, in: webView)
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
      decisionHandler(Self.allowedSchemes.contains(scheme) ? .allow : .cancel)
    }

    var navigated: (URL) -> Void = { _ in }
    var scrolled: (Double) -> Void = { _ in }
    var reloads = 0
    private var observations: [NSKeyValueObservation] = []
    /// Until when a scroll is the Mac's, applied here, and not to be told back.
    private var quietUntil = Date.distantPast
    private var lastSentScroll: Double?
    private var pendingScroll: DispatchWorkItem?

    func attach(_ webView: WKWebView) {
      observations.append(
        webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
          MainActor.assumeIsolated {
            guard let url = webView.url else { return }
            self?.navigated(RemoteWebAddress.unproxied(url))
          }
        })
      observations.append(
        webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
          MainActor.assumeIsolated { self?.userScrolled(scrollView) }
        })
    }

    /// Loads the Mac's page, unless it is already the one shown.
    func show(_ url: URL, in webView: WKWebView) {
      if let current = webView.url,
        RemoteWebAddress.same(
          RemoteWebAddress.unproxied(current).absoluteString, url.absoluteString)
      {
        return
      }
      webView.load(URLRequest(url: RemoteWebAddress.proxied(url)))
    }

    /// Where the Mac's user scrolled, unless that is where the phone already is.
    func scroll(to fraction: Double, in webView: WKWebView) {
      let scrollView = webView.scrollView
      let range = scrollView.contentSize.height - scrollView.bounds.height
      guard range > 0, abs(Self.fraction(of: scrollView) - fraction) > 0.005,
        lastSentScroll.map({ abs($0 - fraction) > 0.005 }) ?? true
      else { return }
      quietUntil = Date().addingTimeInterval(0.4)
      scrollView.setContentOffset(
        CGPoint(x: scrollView.contentOffset.x, y: fraction * range), animated: false)
    }

    /// The phone's user scrolled: told to the Mac, at most every tenth of a second.
    private func userScrolled(_ scrollView: UIScrollView) {
      guard Date() > quietUntil, scrollView.isTracking || scrollView.isDecelerating else {
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
