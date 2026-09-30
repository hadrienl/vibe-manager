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

  @Test("« Open in Browser » lets out a page or a mail address, and runs nothing else (#245)")
  func outside() {
    #expect(LinkRouting.externalRoute(for: web) == .browser)
    #expect(LinkRouting.externalRoute(for: page) == .browser)
    #expect(LinkRouting.externalRoute(for: URL(fileURLWithPath: "/tmp/a.pdf")) == .browser)
    #expect(LinkRouting.externalRoute(for: mail) == .system)
    let refused = [
      URL(fileURLWithPath: "/tmp/x.command"),
      URL(fileURLWithPath: "/Applications/Calculator.app"),
      URL(fileURLWithPath: "/tmp/install.pkg"),
      URL(string: "x-apple.systempreferences:com.apple")!,
      URL(string: "javascript:alert(1)")!,
      URL(string: "vnc://host")!,
      URL(string: "smb://host/share")!,
      URL(string: "afp://host/share")!,
      URL(string: "FILE:///tmp/x.command")!,
      URL(string: "SMB://host/share")!,
    ]
    for url in refused {
      #expect(LinkRouting.externalRoute(for: url) == .refused)
      #expect(!LinkRouting.opensOutside(url))
      #expect(ExternalOpening.plan(for: url) == nil)
    }
    #expect(LinkRouting.opensOutside(web))
    #expect(LinkRouting.opensOutside(mail))
    #expect(LinkRouting.opensOutside(URL(string: "HTTPS://github.com")!))
  }

  @Test("A page is handed to the default browser by name, a mail address to Mail (#245)")
  func plans() {
    #expect(ExternalOpening.plan(for: web) == .inBrowser(web))
    #expect(ExternalOpening.plan(for: page) == .inBrowser(page))
    #expect(ExternalOpening.plan(for: mail) == .withMailApplication(mail))
  }

  @Test("A page file is what it is, not what its name says: links, aliases and folders (#245)")
  func pageFilesAreLookedAt() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-245-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("run.command")
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
    let real = folder.appendingPathComponent("real.html")
    try Data("<p>hi</p>".utf8).write(to: real)

    // `index.html -> run.command`, as a repository can carry it: macOS would hand it to Terminal.
    let link = folder.appendingPathComponent("index.html")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
    // The same with a Finder alias.
    let alias = folder.appendingPathComponent("alias.html")
    try URL.writeBookmarkData(
      try script.bookmarkData(options: .suitableForBookmarkFile), to: alias)
    // A folder, and a package, named like pages.
    let bundle = folder.appendingPathComponent("Bundle.html", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let app = folder.appendingPathComponent("x.app.html", isDirectory: true)
    try FileManager.default.createDirectory(
      at: app.appendingPathComponent("Contents", isDirectory: true),
      withIntermediateDirectories: true)
    // A link and an alias to a real page stay pages.
    let pageLink = folder.appendingPathComponent("page-link.html")
    try FileManager.default.createSymbolicLink(at: pageLink, withDestinationURL: real)
    let pageAlias = folder.appendingPathComponent("page-alias.html")
    try URL.writeBookmarkData(
      try real.bookmarkData(options: .suitableForBookmarkFile), to: pageAlias)
    // A link that leads nowhere.
    let dangling = folder.appendingPathComponent("gone.html")
    try FileManager.default.createSymbolicLink(
      at: dangling, withDestinationURL: folder.appendingPathComponent("missing.command"))

    for refused in [link, alias, bundle, app, dangling] {
      #expect(!LinkRouting.isPage(refused), "\(refused.lastPathComponent)")
      #expect(LinkRouting.externalRoute(for: refused) == .refused)
      #expect(ExternalOpening.plan(for: refused) == nil)
    }
    for page in [real, pageLink, pageAlias] {
      #expect(LinkRouting.isPage(page), "\(page.lastPathComponent)")
      #expect(ExternalOpening.plan(for: page) == .inBrowser(page))
    }
    // Nothing there yet: nothing to run, judged by its name.
    #expect(LinkRouting.isPage(folder.appendingPathComponent("later.html")))
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
