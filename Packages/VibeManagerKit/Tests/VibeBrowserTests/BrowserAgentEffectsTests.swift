import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

/// What a page does after an agent touched its tab — a download, another application's address —
/// stays the agent's doing, however long after; a page's own script never opens an application
/// unasked; every download carries macOS's quarantine (#241).
@Suite("What a page causes after the agent", .serialized)
@MainActor
struct BrowserAgentEffectsTests {
  /// A folder of the test's instead of the user's Downloads, given back once done.
  private final class DownloadFolder {
    let url: URL
    private let previous: @MainActor () -> URL

    @MainActor
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeDownloads-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      previous = BrowserDownloads.shared.folder
      let folder = url
      BrowserDownloads.shared.folder = { folder }
    }

    @MainActor
    func restore() {
      BrowserDownloads.shared.folder = previous
      try? FileManager.default.removeItem(at: url)
    }

    var files: [String] {
      (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }
  }

  /// A page whose script, after `delay` milliseconds, clicks a link the user never touched.
  private static func clicking(_ href: String, download: String? = nil, after delay: Int) -> String
  {
    let attribute = download.map { " download=\"\($0)\"" } ?? ""
    return """
      <!doctype html><title>Page</title><a id="link" href="\(href)"\(attribute)>link</a>
      <script>setTimeout(() => document.getElementById('link').click(), \(delay))</script>
      """
  }

  private func effects(of workspace: BrowserWorkspace, in session: SessionID)
    -> [BrowserAgentEffect]
  {
    workspace.requests(for: session).compactMap {
      if case .effect(let effect) = $0.kind { return effect }
      return nil
    }
  }

  @Test("A download the agent's page starts long after its action is asked; a no saves nothing")
  func lateDownloadAsked() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    // Later than the two to three seconds the old guard lasted.
    let server = try TestPageServer(pages: [
      "/": Self.clicking("/tool.command", download: "tool.command", after: 3_500),
      "/tool.command": "echo owned",
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let opened = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    #expect(!opened.isError)

    await waitUntil("the download is asked") {
      self.effects(of: workspace, in: session) == [.download(filename: "tool.command")]
    }
    let request = try #require(workspace.requests(for: session).first)
    workspace.answer(request, with: .deny)
    await waitUntil("the download is over") {
      workspace.pendingRequests.isEmpty && BrowserDownloads.shared.underWay == 0
    }
    #expect(folder.files.isEmpty)
  }

  @Test("The same download, allowed, is saved and marked as downloaded from its page")
  func allowedDownloadQuarantined() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    let server = try TestPageServer(pages: [
      "/": Self.clicking("/tool.command", download: "tool.command", after: 300),
      "/tool.command": "echo owned",
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(server.url("/"), in: session, openedBy: .agent, activate: false)
    tab.ensureWebView()

    await waitUntil("the download is asked") { !self.effects(of: workspace, in: session).isEmpty }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .allowOnce)
    let file = folder.url.appendingPathComponent("tool.command")
    await waitUntil("the file is marked as downloaded") {
      Self.quarantine(of: file)?[kLSQuarantineTypeKey as String] as? String
        == kLSQuarantineTypeWebDownload as String
    }
    let properties = try #require(Self.quarantine(of: file))
    #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Vibe Manager")
    // Where it came from goes to Launch Services' record of quarantine events, which this process
    // is not given back: what the file itself carries is checked.
    #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
  }

  @Test("A download in the user's tab is not asked, and is marked too")
  func userDownloadQuarantined() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    let server = try TestPageServer(pages: [
      "/": Self.clicking("/notes.txt", download: "notes.txt", after: 300),
      "/notes.txt": "notes",
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = workspace.open(server.url("/"), in: session, openedBy: .user, activate: false)

    let file = folder.url.appendingPathComponent("notes.txt")
    await waitUntil("the file is marked as downloaded") {
      Self.quarantine(of: file)?[kLSQuarantineTypeKey as String] as? String
        == kLSQuarantineTypeWebDownload as String
    }
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("Once the user acts in the agent's tab, what its page does is theirs")
  func userTakesTheTabBack() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    let server = try TestPageServer(pages: [
      "/": Self.clicking("/notes.txt", download: "notes.txt", after: 300),
      "/notes.txt": "notes",
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(server.url("/"), in: session, openedBy: .agent, activate: false)
    #expect(tab.isAgentDriven)
    tab.userDidInteract()
    tab.ensureWebView()

    await waitUntil("the file is saved") { folder.files == ["notes.txt"] }
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("A click the page's own script makes never opens another application")
  func scriptedClickOpensNothing() async throws {
    let server = try TestPageServer(pages: ["/": Self.clicking("vibetest://open", after: 300)])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(server.url("/"), in: session, openedBy: .user, activate: false)
    var opened: [URL] = []
    tab.openApplicationAddress = { opened.append($0) }

    await waitUntil("the page is told it was blocked") {
      tab.console.entries.contains { $0.text.contains("Blocked opening vibetest") }
    }
    #expect(opened.isEmpty)
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("In the agent's tab, the same click is asked, and a no opens nothing")
  func scriptedClickInAgentTabAsked() async throws {
    let server = try TestPageServer(pages: ["/": Self.clicking("vibetest://open", after: 300)])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(server.url("/"), in: session, openedBy: .agent, activate: false)
    var opened: [URL] = []
    tab.openApplicationAddress = { opened.append($0) }
    tab.ensureWebView()

    await waitUntil("the application is asked") {
      self.effects(of: workspace, in: session)
        == [.externalApplication(URL(string: "vibetest://open")!)]
    }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .deny)
    await waitUntil("the question is gone") { workspace.pendingRequests.isEmpty }
    #expect(opened.isEmpty)
  }

  @Test("An action makes the tab the agent's until the user acts, whatever time passes")
  func agentStateHasNoDeadline() {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(
      URL(string: "https://example.com")!, in: session, openedBy: .user, activate: false)
    #expect(!tab.isAgentDriven)
    workspace.willAct(on: tab)
    workspace.didAct(on: tab)
    #expect(tab.isAgentDriven)
    tab.userDidInteract()
    #expect(!tab.isAgentDriven)
  }

  @Test("A download whose tab is closed before the server answers is refused, never saved")
  func closedBeforeTheAnswer() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    let server = try TestPageServer(pages: [
      "/": Self.clicking("/slow.command", download: "slow.command", after: 200),
      "/slow.command": "echo owned",
    ])
    server.hold("/slow.command")
    defer {
      server.release("/slow.command")
      server.stop()
    }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let opened = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    #expect(!opened.isError)
    await waitUntil("the download is under way") { server.wasAsked("/slow.command") }
    // Only the identifier is kept: nothing of the test holds the closed tab.
    let tabID = try #require(workspace.browser(for: session).activeTab?.id)
    workspace.close(tabID, in: session)
    server.release("/slow.command")

    await waitUntil("the download is over") { BrowserDownloads.shared.underWay == 0 }
    #expect(workspace.pendingRequests.isEmpty)
    #expect(folder.files.isEmpty)
  }

  @Test("A tab the agent sent somewhere stays the agent's once the application relaunches")
  func agentStateKept() throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(
      URL(string: "https://example.com")!, in: session, openedBy: .user, activate: false)
    workspace.willAct(on: tab)
    workspace.didAct(on: tab)
    let kept = try JSONDecoder().decode(
      BrowserTab.self, from: try JSONEncoder().encode(tab.persisted))
    #expect(kept.openedBy == .user)
    #expect(kept.isAgentDriven)
    let restored = workspace.makeTab(
      kept.url, id: kept.id, title: kept.title, openedBy: kept.openedBy,
      isAgentDriven: kept.isAgentDriven, in: session)
    #expect(restored.isAgentDriven)

    // What a build before #241, or a later one, wrote is the agent's.
    let id = UUID().uuidString
    let older = #"{"id":"\#(id)","url":"https://example.com","title":"","openedBy":"user"}"#
    #expect(try JSONDecoder().decode(BrowserTab.self, from: Data(older.utf8)).isAgentDriven)
    let later = #"{"id":"\#(id)","url":"https://example.com","openedBy":"assistant"}"#
    #expect(try JSONDecoder().decode(BrowserTab.self, from: Data(later.utf8)).openedBy == .agent)
  }

  @Test("Only a click of the main button or typed text hands the tab back")
  func whatHandsTheTabBack() throws {
    func mouse(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) throws
      -> NSEvent
    {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: 0, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }
    #expect(SessionWebView.handsTabBack(try mouse(.leftMouseDown)))
    #expect(!SessionWebView.handsTabBack(try mouse(.leftMouseDown, .control)))
    #expect(!SessionWebView.handsTabBack(try mouse(.rightMouseDown)))
    #expect(!SessionWebView.handsTabBack(try mouse(.otherMouseDown)))
    #expect(SessionWebView.handsTabBack(try key("a")))
    #expect(!SessionWebView.handsTabBack(try key(" ")))
    #expect(!SessionWebView.handsTabBack(try key("\u{F701}")))
    #expect(!SessionWebView.handsTabBack(try key("\r")))
    #expect(!SessionWebView.handsTabBack(try key("a", .command)))
  }

  @Test("An address that reaches another computer is asked even after a click of the user's")
  func networkAddressAsked() async throws {
    let server = try TestPageServer(pages: [
      "/": #"<!doctype html><title>Page</title><a id="link" href="smb://server/share">x</a>"#
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(server.url("/"), in: session, openedBy: .user, activate: false)
    var opened: [URL] = []
    tab.openApplicationAddress = { opened.append($0) }
    await waitUntil("the page is loaded") { tab.committedURL != nil && !tab.isLoading }
    let view = try #require(tab.webView as? SessionWebView)
    view.notePress(at: ProcessInfo.processInfo.systemUptime, modifiers: [])
    _ = try? await view.evaluateJavaScript("document.getElementById('link').click()")

    await waitUntil("the address is asked") {
      self.effects(of: workspace, in: session)
        == [.networkAddress(URL(string: "smb://server/share")!)]
    }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .deny)
    await waitUntil("the question is gone") { workspace.pendingRequests.isEmpty }
    #expect(opened.isEmpty)
  }

  /// The application address the pages below send.
  private static let application = URL(string: "vibetest://open")!

  /// A page of the user's, loaded, whose openings are noted instead of done.
  @MainActor
  private struct UserPage {
    let server: TestPageServer
    let workspace: BrowserWorkspace
    let session = SessionID()
    let tab: BrowserTabModel
    let view: SessionWebView
    let opened: () -> [URL]

    init(_ html: String) async throws {
      server = try TestPageServer(pages: ["/": html])
      workspace = BrowserWorkspace()
      tab = workspace.open(server.url("/"), in: session, openedBy: .user, activate: false)
      var opened: [URL] = []
      tab.openApplicationAddress = { opened.append($0) }
      self.opened = { opened }
      let tab = tab
      await waitUntil("the page is loaded") { tab.committedURL != nil && !tab.isLoading }
      view = try #require(tab.webView as? SessionWebView)
    }

    /// A press of the user's, then a click on `element`.
    func pressThenClick(_ element: String) async {
      view.notePress(at: ProcessInfo.processInfo.systemUptime, modifiers: [])
      _ = try? await view.evaluateJavaScript("document.getElementById('\(element)').click()")
    }

    var applicationsAsked: [URL] {
      workspace.requests(for: session).compactMap {
        if case .effect(.pageApplication(let url, _)) = $0.kind { return url }
        return nil
      }
    }
  }

  @Test("After a click of the user's, an application address the page's script sends is asked")
  func pageScriptAfterClickAsked() async throws {
    // The user clicks a button; the page's handler sends an address they never saw (#289).
    let page = try await UserPage(
      #"""
      <!doctype html><title>Page</title><a id="hidden" href="vibetest://open"></a>
      <a id="other" href="vibetest2://open"></a>
      <button id="b" onclick="document.getElementById('hidden').click()">Play</button>
      <button id="c" onclick="document.getElementById('other').click()">Again</button>
      """#)
    defer { page.server.stop() }
    await page.pressThenClick("b")
    await waitUntil("the application is asked") { page.applicationsAsked == [Self.application] }
    page.workspace.answer(
      try #require(page.workspace.requests(for: page.session).first), with: .deny)
    // The refusal is settled once a later question, on another scheme, is answered: tasks resume
    // in order on the main actor, so the first would have opened before the second.
    await page.pressThenClick("c")
    await waitUntil("the second application is asked") { page.applicationsAsked.count == 1 }
    page.workspace.answer(
      try #require(page.workspace.requests(for: page.session).first), with: .allowOnce)
    await waitUntil("the second address is opened") { !page.opened().isEmpty }
    #expect(page.opened() == [URL(string: "vibetest2://open")!])
  }

  @Test("One click of the user's is one question, and a refused scheme is not asked again")
  func onePressOneQuestion() async throws {
    let page = try await UserPage(
      #"""
      <!doctype html><title>Page</title><a id="l1" href="vibetest://one"></a>
      <a id="l2" href="vibetest://two"></a>
      <button id="b" onclick="for (const id of ['l1', 'l2']) document.getElementById(id).click()">
      Play</button>
      <a id="again" href="vibetest://three">Again</a>
      """#)
    defer { page.server.stop() }
    await page.pressThenClick("b")
    await waitUntil("a question is asked") { !page.applicationsAsked.isEmpty }
    // The page's two clicks after one press of the user's: only the first is asked.
    let flushed = try? await page.view.evaluateJavaScript("1")
    #expect(flushed != nil)
    #expect(page.applicationsAsked == [URL(string: "vibetest://one")!])
    page.workspace.answer(
      try #require(page.workspace.requests(for: page.session).first), with: .deny)
    await waitUntil("the question is gone") { page.workspace.pendingRequests.isEmpty }
    // The same scheme again, after another press: refused on this page, not asked.
    await page.pressThenClick("again")
    await waitUntil("the page is told it was blocked") {
      page.tab.console.entries.contains { $0.text.contains("refused it on this page") }
    }
    #expect(page.workspace.pendingRequests.isEmpty)
    #expect(page.opened().isEmpty)
  }

  @Test("The question names the site of the frame that sends the address")
  func questionNamesTheFrame() async throws {
    let page = try await UserPage(
      #"<!doctype html><title>Page</title><a id="link" href="vibetest://open">x</a>"#)
    defer { page.server.stop() }
    await page.pressThenClick("link")
    await waitUntil("the application is asked") { page.applicationsAsked == [Self.application] }
    let request = try #require(page.workspace.requests(for: page.session).first)
    guard case .effect(.pageApplication(_, let site)) = request.kind else {
      Issue.record("Not a page's question: \(request.kind)")
      return
    }
    #expect(site == "127.0.0.1:\(page.server.port)")
  }

  @Test("An application address the user clicks is asked too, and opens once allowed")
  func userClickedApplicationAsked() async throws {
    let page = try await UserPage(
      #"<!doctype html><title>Page</title><a id="link" href="vibetest://open">x</a>"#)
    defer { page.server.stop() }
    await page.pressThenClick("link")
    await waitUntil("the application is asked") { page.applicationsAsked == [Self.application] }
    #expect(page.opened().isEmpty)
    page.workspace.answer(
      try #require(page.workspace.requests(for: page.session).first), with: .allowOnce)
    await waitUntil("the address is opened") { page.opened() == [Self.application] }
  }

  @Test("A window the agent's page opened stays asked after the user clicks in it")
  func windowOfTheAgentsPage() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    let server = try TestPageServer(pages: [
      "/": "<title>Opener</title>",
      "/window": Self.clicking("/notes.txt", download: "notes.txt", after: 300),
      "/notes.txt": "notes",
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let opener = workspace.open(server.url("/"), in: session, openedBy: .agent, activate: false)
    let window = workspace.open(
      server.url("/window"), in: session, openedBy: .agent, activate: false, from: opener.id)
    #expect(window.isOpenedByAgentPage)
    window.userDidInteract()
    #expect(window.asksBeforeEffects)
    window.ensureWebView()

    await waitUntil("the download is asked") {
      self.effects(of: workspace, in: session) == [.download(filename: "notes.txt")]
    }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .deny)
    await waitUntil("the download is over") { BrowserDownloads.shared.underWay == 0 }
    #expect(folder.files.isEmpty)
  }

  @Test("A response that cannot be shown, and a blob, are downloads asked in the agent's tab")
  func otherWaysToDownload() async throws {
    let folder = try DownloadFolder()
    defer { folder.restore() }
    let server = try TestPageServer(pages: [
      "/": """
      <!doctype html><title>Page</title><script>setTimeout(() => {
        location.href = '/archive.bin'
      }, 300)</script>
      """,
      "/archive.bin": "binary",
      "/blob": """
      <!doctype html><title>Blob</title><script>setTimeout(() => {
        const link = document.createElement('a')
        link.href = URL.createObjectURL(new Blob(['made here'], {type: 'text/plain'}))
        link.download = 'made.txt'
        document.body.appendChild(link)
        link.click()
      }, 300)</script>
      """,
    ])
    server.setContentType("/archive.bin", "application/octet-stream")
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()

    let first = workspace.open(server.url("/"), in: session, openedBy: .agent, activate: false)
    first.ensureWebView()
    await waitUntil("the response is asked") {
      self.effects(of: workspace, in: session) == [.download(filename: "archive.bin")]
    }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .deny)
    await waitUntil("the first download is over") { BrowserDownloads.shared.underWay == 0 }

    let second = workspace.open(
      server.url("/blob"), in: session, openedBy: .agent, activate: false)
    second.ensureWebView()
    await waitUntil("the blob is asked") {
      self.effects(of: workspace, in: session) == [.download(filename: "made.txt")]
    }
    workspace.answer(try #require(workspace.requests(for: session).first), with: .deny)
    await waitUntil("the second download is over") { BrowserDownloads.shared.underWay == 0 }
    #expect(folder.files.isEmpty)
  }

  @Test("A file's name cannot pass for another, and a blob's address is not kept")
  func namesAndAddresses() {
    #expect(BrowserDownloads.safeName("invoice\u{202E}fdp.command") == "invoicefdp.command")
    #expect(BrowserDownloads.safeName("a\u{0007}b\u{2066}.pkg") == "ab.pkg")
    #expect(BrowserDownloads.safeName("../../evil.app") == "evil.app")
    #expect(BrowserDownloads.safeName("") == "download")

    let page = URL(string: "https://example.com/page")!
    let kept = BrowserDownloads.quarantineProperties(
      address: URL(string: "https://example.com/tool.pkg"), page: page)
    #expect(kept[kLSQuarantineDataURLKey as String] as? URL != nil)
    #expect(kept[kLSQuarantineOriginURLKey as String] as? URL == page)
    let blob = BrowserDownloads.quarantineProperties(
      address: URL(string: "blob:https://example.com/1234"), page: page)
    #expect(blob[kLSQuarantineDataURLKey as String] == nil)
    let data = BrowserDownloads.quarantineProperties(
      address: URL(string: "data:text/plain,hello"), page: nil)
    #expect(data[kLSQuarantineDataURLKey as String] == nil)
    #expect(data[kLSQuarantineOriginURLKey as String] == nil)
  }

  private static func quarantine(of file: URL) -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return try? file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
  }
}
