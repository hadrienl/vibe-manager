import AppKit

/// How an address that `LinkRouting` lets out of the application is handed to macOS (#245).
///
/// A page is opened **with the default browser, named explicitly**, never left to the application
/// macOS picks for the file: « Open in Browser » keeps its word, and a page file that is something
/// else in disguise is shown as text by a browser rather than run. A mail address goes to the mail
/// application. Anything else is not opened.
public enum ExternalOpening: Equatable, Sendable {
  /// A page, in the default browser.
  case inBrowser(URL)
  /// A `mailto:` address, with the application macOS has for it.
  case withMailApplication(URL)

  /// What `open` would do with `url`; `nil` when it opens nothing.
  public static func plan(for url: URL) -> ExternalOpening? {
    switch LinkRouting.externalRoute(for: url) {
    case .browser: .inBrowser(url)
    case .system: .withMailApplication(url)
    case .webView, .newTab, .refused: nil
    }
  }

  /// Opens `url` as `plan(for:)` says. Returns whether anything was handed to macOS.
  @MainActor
  @discardableResult
  public static func open(_ url: URL) -> Bool {
    switch plan(for: url) {
    case .inBrowser(let page):
      guard let probe = URL(string: "https://example.com"),
        let browser = NSWorkspace.shared.urlForApplication(toOpen: probe)
      else { return false }
      // Opens outside: a page (`LinkRouting.isPage`), in the default browser named explicitly.
      NSWorkspace.shared.open(
        [page], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
      return true
    case .withMailApplication(let address):
      // Opens outside: a mail address (`LinkRouting.isMail`), which only drafts a message.
      return NSWorkspace.shared.open(address)
    case nil:
      return false
    }
  }
}
