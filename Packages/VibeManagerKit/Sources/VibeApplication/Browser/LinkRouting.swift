import Foundation
import UniformTypeIdentifiers

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
  ///
  /// A file is judged by what it is, not by the name in the address (#245): `index.html` may be a
  /// symbolic link or a Finder alias to `run.command`, which macOS would hand to Terminal. Links and
  /// aliases are followed, and the file they lead to must be a page; a folder or a package never is.
  /// A file that does not exist yet has nothing to run, and is judged by its name.
  public static func isPage(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == "http" || scheme == "https" { return true }
    guard url.isFileURL, pageExtensions.contains(url.pathExtension.lowercased()) else {
      return false
    }
    return isPageFile(url)
  }

  private static let pageExtensions: Set<String> = ["html", "htm", "svg", "pdf"]
  private static let pageTypes: [UTType] = [.html, .svg, .pdf, .webArchive]

  /// Whether the file at `url`, once its links and aliases are followed, is a page.
  static func isPageFile(_ url: URL) -> Bool {
    var target = url
    // A link to a link, or an alias to a link, is followed a few steps, and refused beyond.
    for step in 0..<8 {
      let resolved = target.resolvingSymlinksInPath()
      guard let values = try? resolved.resourceValues(forKeys: [.isAliasFileKey]) else {
        // Nothing at all at the address has nothing to run. A link or an alias that leads nowhere
        // may lead anywhere later, and is refused.
        return step == 0
          && (try? FileManager.default.attributesOfItem(atPath: resolved.path)) == nil
      }
      guard values.isAliasFile == true else { return isPageType(resolved) }
      guard
        let aliased = try? URL(
          resolvingAliasFileAt: resolved, options: [.withoutUI, .withoutMounting])
      else { return false }
      target = aliased
    }
    return false
  }

  private static func isPageType(_ url: URL) -> Bool {
    let keys: Set<URLResourceKey> = [
      .contentTypeKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys),
      values.isDirectory != true, values.isPackage != true, values.isSymbolicLink != true,
      values.isAliasFile != true, let type = values.contentType
    else { return false }
    return pageTypes.contains { type.conforms(to: $0) }
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

  /// Where an address goes when it is asked to leave the application — « Open in Browser » (#245):
  /// the default browser for a page, the mail application for an address, and nowhere otherwise, so
  /// that a tab showing `file:///…/x.command` never runs it.
  public static func externalRoute(for url: URL) -> LinkRoute {
    route(url, gesture: .browser, preference: .defaultBrowser, hasWebView: false)
  }

  /// Whether `externalRoute(for:)` opens the address somewhere: a button that would not is greyed.
  public static func opensOutside(_ url: URL) -> Bool {
    externalRoute(for: url) != .refused
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
