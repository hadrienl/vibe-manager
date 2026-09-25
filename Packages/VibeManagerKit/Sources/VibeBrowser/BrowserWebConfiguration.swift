import AppKit
import Foundation
import WebKit

/// How every page of every session is set up (#69).
///
/// One website data store for the whole application, apart from Safari's and kept on disk: the
/// user signs in to GitHub or GitLab once, and every session's ticket tab is signed in. An isolated
/// copy of the application has a store of its own, named by an identifier written in its data
/// folder.
@MainActor
public final class BrowserWebConfiguration {
  private let dataStore: WKWebsiteDataStore
  private let agentWorld = WKContentWorld.world(name: PageScripts.agentWorldName)
  /// Where pages wait when no panel shows them: in a window, so that they keep laying out, running
  /// and answering a screenshot. Absent where there is no application to own a window (tests).
  private var parking: NSWindow?

  /// - Parameter storeIdentifierFile: where the data store's identifier is kept. `nil` keeps
  ///   nothing on disk, as tests want.
  public init(storeIdentifierFile: URL?) {
    if let storeIdentifierFile {
      dataStore = WKWebsiteDataStore(forIdentifier: Self.identifier(at: storeIdentifierFile))
    } else {
      dataStore = .nonPersistent()
    }
  }

  func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    // Safari's user agent: sign-in pages — Google's first — refuse a browser they cannot name,
    // taking it for an application's embedded view.
    configuration.applicationNameForUserAgent = Self.safariApplicationName
    configuration.preferences.isElementFullscreenEnabled = true
    let controller = WKUserContentController()
    controller.addUserScript(
      WKUserScript(
        source: PageScripts.console, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: .page))
    controller.addUserScript(
      WKUserScript(
        source: PageScripts.agent, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: agentWorld))
    configuration.userContentController = controller
    // A web view the user browses with: it goes wherever they, or their agent, send it. What an
    // agent may do there is bounded by `BrowserActionPolicy` (ADR 0023), not by where it can go.
    let webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.allowsMagnification = true
    // Safari's Web Inspector, from the page's context menu, in a development build only: a
    // released application does not open its pages to another program's debugger.
    #if DEBUG
      webView.isInspectable = true
    #endif
    return webView
  }

  func attachConsole(to webView: WKWebView, handler: any WKScriptMessageHandler) {
    webView.configuration.userContentController.add(
      handler, contentWorld: .page, name: PageScripts.consoleHandlerName)
  }

  /// Runs one of the agent's helpers in its own world.
  func callAgent(_ body: String, arguments: [String: Any], in webView: WKWebView) async throws
    -> Any?
  {
    try await webView.callAsyncJavaScript(
      body, arguments: arguments, in: nil, contentWorld: agentWorld)
  }

  static let safariApplicationName = "Version/18.5 Safari/605.1.15"

  /// Puts a page nobody shows in the parking window.
  func park(_ webView: WKWebView) {
    guard webView.superview == nil, let parking = parkingWindow() else { return }
    parking.contentView?.addSubview(webView)
  }

  func unpark(_ webView: WKWebView) {
    if webView.window === parking { webView.removeFromSuperview() }
  }

  private func parkingWindow() -> NSWindow? {
    if let parking { return parking }
    guard NSApp != nil else { return nil }
    let window = NSWindow(
      contentRect: NSRect(x: -32_000, y: -32_000, width: 1_280, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = true
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 800))
    window.orderFrontRegardless()
    parking = window
    return window
  }

  /// Forgets every cookie, cache and storage of the pages: Settings › Web View › Clear.
  public func clearBrowsingData() async {
    await dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
  }

  private static func identifier(at file: URL) -> UUID {
    if let text = try? String(contentsOf: file, encoding: .utf8),
      let identifier = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return identifier
    }
    let identifier = UUID()
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(
      atPath: file.path, contents: Data(identifier.uuidString.utf8),
      attributes: [.posixPermissions: 0o600])
    return identifier
  }
}
