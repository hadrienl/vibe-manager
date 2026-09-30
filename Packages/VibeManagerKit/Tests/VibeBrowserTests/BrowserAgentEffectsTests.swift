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
    await waitUntil("the question is gone") { workspace.pendingRequests.isEmpty }
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

  private static func quarantine(of file: URL) -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return try? file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
  }
}
