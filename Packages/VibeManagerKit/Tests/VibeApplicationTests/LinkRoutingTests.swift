import Foundation
import Testing
import VibeApplication
import VibeLocalizationTesting

@Suite("Where a clicked link goes (#186)")
struct LinkRoutingTests {
  private let web = URL(string: "https://github.com/o/r/pull/3")!
  private let page = URL(fileURLWithPath: "/tmp/report.html")
  private let mail = URL(string: "mailto:someone@example.com")!

  private func route(
    _ url: URL, _ gesture: LinkGesture, preference: LinkDestination = .webView,
    hasWebView: Bool = true
  ) -> LinkRoute {
    LinkRouting.route(url, gesture: gesture, preference: preference, hasWebView: hasWebView)
  }

  @Test("A click follows Settings, and ⌥ does the other")
  func clickFollowsSettings() {
    #expect(route(web, .click(alternate: false)) == .webView)
    #expect(route(web, .click(alternate: true)) == .browser)
    #expect(route(web, .click(alternate: false), preference: .defaultBrowser) == .browser)
    #expect(route(web, .click(alternate: true), preference: .defaultBrowser) == .webView)
  }

  @Test("A page of this Mac opens as a web page does")
  func filePages() {
    #expect(route(page, .click(alternate: false)) == .webView)
    for name in ["a.htm", "a.svg", "a.PDF"] {
      #expect(route(URL(fileURLWithPath: "/tmp/\(name)"), .newTab) == .newTab)
    }
  }

  @Test("What is not a page is never run by a click")
  func refusesWhatIsNotAPage() {
    let refused = [
      URL(fileURLWithPath: "/Applications/Calculator.app"),
      URL(fileURLWithPath: "/tmp/run.command"),
      URL(string: "x-apple.systempreferences:com.apple")!,
      URL(string: "javascript:alert(1)")!,
      URL(string: "ssh://host")!,
    ]
    for url in refused {
      #expect(route(url, .click(alternate: false)) == .refused)
      #expect(route(url, .browser) == .refused)
    }
  }

  @Test("A mail address goes to the mail application, whatever the gesture")
  func mailGoesToTheSystem() {
    #expect(route(mail, .click(alternate: false)) == .system)
    #expect(route(mail, .click(alternate: true)) == .system)
    #expect(route(mail, .newTab) == .system)
  }

  @Test("A link's menu says where, whatever Settings and ⌥ say")
  func menuGestures() {
    #expect(route(web, .webView, preference: .defaultBrowser) == .webView)
    #expect(route(web, .newTab, preference: .defaultBrowser) == .newTab)
    #expect(route(web, .browser, preference: .webView) == .browser)
  }

  @Test("Without a web view — none, or the session archived — the default browser shows it")
  func withoutWebView() {
    #expect(route(web, .click(alternate: false), hasWebView: false) == .browser)
    #expect(route(web, .webView, hasWebView: false) == .browser)
    #expect(route(web, .newTab, hasWebView: false) == .browser)
    #expect(route(web, .browser, hasWebView: false) == .browser)
  }

  @Test("Every link's menu offers the external browser, and the web view only when there is one")
  func menuActions() {
    #expect(
      LinkMenuAction.actions(for: web, hasWebView: true) == [
        .openInWebView, .openInNewTab, .openInExternalBrowser, .copy,
      ])
    #expect(
      LinkMenuAction.actions(for: web, hasWebView: false) == [.openInExternalBrowser, .copy])
    #expect(LinkMenuAction.actions(for: mail, hasWebView: true) == [.copy])
    #expect(
      LinkMenuAction.actions(for: URL(fileURLWithPath: "/tmp/run.command"), hasWebView: true)
        == [.copy])
    #expect(LinkMenuAction.openInExternalBrowser.gesture == .browser)
    #expect(LinkMenuAction.copy.gesture == nil)
  }

  @Test("The actions of a link's menu, in French")
  func frenchTitles() {
    let french = [
      Localization.string("Open in the Web View", module: "VibeApplication", in: "fr"),
      Localization.string("Open in a New Tab", module: "VibeApplication", in: "fr"),
      Localization.string("Open in the External Browser", module: "VibeApplication", in: "fr"),
      Localization.string("Copy Link", module: "VibeApplication", in: "fr"),
    ]
    #expect(
      french == [
        "Ouvrir dans la vue web", "Ouvrir dans un nouvel onglet",
        "Ouvrir dans le navigateur externe", "Copier le lien",
      ])
  }
}
