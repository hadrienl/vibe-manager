import Foundation

/// Where a clicked link goes, as Settings › Web View say (#69, #186).
public enum LinkDestination: String, Codable, CaseIterable, Sendable {
  case webView
  case defaultBrowser
}

/// How the user asked for a link: a click, which follows Settings and ⌥, or one of the actions of a
/// link's menu, which says where.
public enum LinkGesture: Equatable, Sendable {
  case click(alternate: Bool)
  /// The session's web view: the tab that already shows the address, else a new one.
  case webView
  /// A new tab of the session's web view, even when one already shows the address.
  case newTab
  /// The default browser, whatever Settings say.
  case browser
}

/// What is done with a link.
public enum LinkRoute: Equatable, Sendable {
  /// The tab of the session's web view that shows the address, else a new one.
  case webView
  case newTab
  case browser
  /// Handed to macOS: a `mailto:` address.
  case system
  /// Not opened: the user hears a beep.
  case refused
}

/// The one rule every link of a session follows — the terminal's, the conversation's, the activity's
/// and the notes' (#186).
public enum LinkRouting {
  /// What shows a page. A link's text and its address can differ (OSC 8), and output is anybody's:
  /// another application's address, or a file that is not a page — a `.command`, an app — is not
  /// run on a click.
  public static func isPage(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == "http" || scheme == "https" { return true }
    return url.isFileURL && ["html", "htm", "svg", "pdf"].contains(url.pathExtension.lowercased())
  }

  public static func isMail(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "mailto"
  }

  /// `hasWebView` is false when the session has none: no web view at all, or archived.
  public static func route(
    _ url: URL, gesture: LinkGesture, preference: LinkDestination, hasWebView: Bool
  ) -> LinkRoute {
    if isMail(url) { return .system }
    guard isPage(url) else { return .refused }
    let wanted: LinkRoute
    switch gesture {
    case .click(let alternate):
      let inWebView = (preference == .webView) != alternate
      wanted = inWebView ? .webView : .browser
    case .webView: wanted = .webView
    case .newTab: wanted = .newTab
    case .browser: wanted = .browser
    }
    return hasWebView || wanted == .browser ? wanted : .browser
  }
}

/// What a link's context menu offers, wherever the link is: the terminal, the conversation, the
/// activity, the notes, a page of the web view (#186). Described once so that every menu reads the
/// same.
public enum LinkMenuAction: Equatable, Sendable {
  case openInWebView
  case openInNewTab
  case openInExternalBrowser
  case copy

  /// The actions for a link, in order: those of the web view only when the session has one; none
  /// that opens when the address is not a page.
  public static func actions(for url: URL, hasWebView: Bool) -> [LinkMenuAction] {
    guard LinkRouting.isPage(url) else { return [.copy] }
    return hasWebView
      ? [.openInWebView, .openInNewTab, .openInExternalBrowser, .copy]
      : [.openInExternalBrowser, .copy]
  }

  /// How the link is opened; `nil` for Copy Link.
  public var gesture: LinkGesture? {
    switch self {
    case .openInWebView: .webView
    case .openInNewTab: .newTab
    case .openInExternalBrowser: .browser
    case .copy: nil
    }
  }

  public var title: String {
    switch self {
    case .openInWebView:
      String(localized: "Open in the Web View", bundle: .module, comment: "A link's menu.")
    case .openInNewTab:
      String(localized: "Open in a New Tab", bundle: .module, comment: "A link's menu.")
    case .openInExternalBrowser:
      String(localized: "Open in the External Browser", bundle: .module, comment: "A link's menu.")
    case .copy:
      String(localized: "Copy Link", bundle: .module, comment: "A link's menu.")
    }
  }
}
