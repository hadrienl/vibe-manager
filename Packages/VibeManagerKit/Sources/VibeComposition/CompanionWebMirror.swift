import AppKit
import CompanionCore
import Foundation
import VibeBrowser
import VibeDomain
import VibeUI
import WebKit

/// A session's web view, mirrored on a phone (#400): its tabs and a picture of the active page,
/// sent again whenever either changes, and what the phone does there done by the Mac's page —
/// both ways in sync, since the phone shows the very page the Mac does.
///
/// A picture rather than the page loaded again on the phone: the pages an agent shows are often
/// the Mac's own (`localhost:4000`), which the phone cannot reach.
@MainActor
final class CompanionWebMirror {
  /// How often the page is pictured while the phone shows it.
  private static let interval: Duration = .milliseconds(600)
  /// The picture's longest side: sharp on a phone, light on the channel.
  private static let side: CGFloat = 1100

  let sessionID: SessionID
  private weak var appModel: AppModel?
  private let send: @MainActor (RemoteMessage) -> Void
  private var loop: Task<Void, Never>?
  private var lastFrame: Data?
  private var lastState: RemoteWebState?

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
    var frame: Data?
    if let tab = active, let picture = await Self.picture(of: tab.ensureWebView()),
      picture != lastFrame
    {
      lastFrame = picture
      frame = picture
    }
    let state = RemoteWebState(
      sessionID: sessionID.rawValue.uuidString,
      tabs: browser.tabs.map {
        RemoteWebTab(
          id: $0.id.rawValue.uuidString, title: $0.title, url: $0.url.absoluteString,
          isLoading: $0.isLoading)
      },
      activeTabID: active?.id.rawValue.uuidString, canGoBack: active?.canGoBack ?? false,
      canGoForward: active?.canGoForward ?? false, frame: nil)
    guard frame != nil || state != lastState else { return }
    lastState = state
    var sent = state
    sent.frame = frame
    send(.webState(sent))
  }

  /// The visible part of the page, in JPEG. A web view never laid out — its session's web view
  /// never shown on the Mac — is given a window's size first, or there is nothing to picture.
  static func picture(of webView: WKWebView) async -> Data? {
    if webView.bounds.width < 10 || webView.bounds.height < 10 {
      webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    }
    let configuration = WKSnapshotConfiguration()
    let bounds = webView.bounds
    let longest = max(bounds.width, bounds.height)
    if longest > side {
      configuration.snapshotWidth = NSNumber(value: Double(bounds.width * side / longest))
    }
    guard let image = try? await webView.takeSnapshot(configuration: configuration),
      let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
  }

  // MARK: - What the phone does

  func perform(_ action: RemoteWebAction) async {
    guard let workspace = appModel?.browser, let browser else { return }
    let tab = browser.activeTab
    switch action {
    case .tap(let x, let y):
      await run(Self.tapScript(x: x, y: y), in: tab)
    case .scroll(let dy):
      await run("window.scrollBy({top: \(dy) * window.innerHeight, behavior: 'instant'})", in: tab)
    case .type(let text):
      await run(Self.typeScript(text), in: tab)
    case .navigate(let address):
      guard let url = Self.url(from: address) else { return }
      if let tab {
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
    // Pictured at once rather than at the next beat: the phone sees its touch answered.
    try? await Task.sleep(for: .milliseconds(150))
    await tick()
  }

  private func run(_ script: String, in tab: BrowserTabModel?) async {
    guard let webView = tab?.webView else { return }
    _ = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
  }

  /// A touch as a mouse would make it on the element under it: pointer and mouse events, then
  /// a click, which follows links and presses buttons; a field gets the focus.
  static func tapScript(x: Double, y: Double) -> String {
    """
    (() => {
      const x = \(x) * window.innerWidth, y = \(y) * window.innerHeight;
      const el = document.elementFromPoint(x, y);
      if (!el) return;
      const options = {bubbles: true, cancelable: true, clientX: x, clientY: y, view: window};
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
        const Event = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        el.dispatchEvent(new Event(type, options));
      }
      if (el.focus) el.focus();
      el.click();
    })()
    """
  }

  /// Text into the focused field, as typed; a line break submits its form.
  static func typeScript(_ text: String) -> String {
    let literal =
      (try? String(data: JSONEncoder().encode(text), encoding: .utf8) ?? "\"\"") ?? "\"\""
    return """
      (() => {
        const text = \(literal);
        const el = document.activeElement;
        if (!el) return;
        for (const [index, line] of text.split('\\n').entries()) {
          if (index > 0) {
            const form = el.form;
            el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
            if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
          }
          if (line) document.execCommand('insertText', false, line);
        }
      })()
      """
  }

  /// What was typed in the address field: an address with its scheme, `localhost:4000` or a
  /// host, as Safari takes them.
  static func url(from address: String) -> URL? {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.contains("://") { return URL(string: text) }
    let isLocal =
      text.hasPrefix("localhost") || text.hasPrefix("127.") || text.range(
        of: #"^[\w.-]+:\d+"#, options: .regularExpression) != nil
    return URL(string: (isLocal ? "http://" : "https://") + text)
  }
}
