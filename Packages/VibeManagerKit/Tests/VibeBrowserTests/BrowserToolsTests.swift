import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

/// A runner that says which tool it was asked for.
@MainActor
private final class EchoRunner: BrowserToolRunning {
  var calls: [(String, SessionID)] = []

  func run(tool: String, arguments: JSONValue, session: SessionID) async -> BrowserToolResult {
    calls.append((tool, session))
    return .text("ran \(tool)")
  }
}

@Suite("Speaking MCP to an agent")
@MainActor
struct BrowserMCPServerTests {
  private func answer(_ line: String, runner: EchoRunner = EchoRunner()) async -> JSONValue? {
    guard
      let data = await BrowserMCPServer.respond(
        to: Data(line.utf8), session: SessionID(), runner: runner)
    else { return nil }
    #expect(data.last == 0x0A)
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  @Test("initialize answers the version asked for when it is known, the latest otherwise")
  func initialize() async throws {
    let known = try #require(
      await answer(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#
      ))
    #expect(known["result"]?["protocolVersion"] == "2025-03-26")
    #expect(known["result"]?["serverInfo"]?["name"] == "vibe-browser")
    let unknown = try #require(
      await answer(
        #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999"}}"#))
    #expect(unknown["id"] == "a")
    #expect(
      unknown["result"]?["protocolVersion"]
        == .string(BrowserMCPServer.supportedProtocolVersions[0]))
  }

  @Test("The tools are listed with their schemas")
  func list() async throws {
    let listed = try #require(await answer(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
    guard case .array(let tools) = listed["result"]?["tools"] ?? .null else {
      Issue.record("no tools")
      return
    }
    let names = tools.compactMap { $0["name"]?.stringValue }
    #expect(names.contains("tab_open"))
    #expect(names.contains("page_evaluate"))
    #expect(names.count == BrowserToolCatalog.tools.count)
    #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })
  }

  @Test("A call reaches the runner for the connection's session; unknown tools do not")
  func call() async throws {
    let runner = EchoRunner()
    let result = try #require(
      await answer(
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tabs_list","arguments":{}}}"#,
        runner: runner))
    #expect(result["result"]?["isError"] == false)
    #expect(runner.calls.map(\.0) == ["tabs_list"])
    let unknown = try #require(
      await answer(
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rm_rf"}}"#, runner: runner
      ))
    #expect(unknown["error"]?["code"] == -32602)
    #expect(runner.calls.count == 1)
  }

  @Test("Notifications are not answered, garbage is")
  func notifications() async {
    #expect(await answer(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(await answer("{nope")?["error"]?["code"] == -32700)
    #expect(
      await answer(#"{"jsonrpc":"2.0","id":5,"method":"sampling/create"}"#)?["error"]?["code"]
        == -32601)
  }
}

@Suite("Driving a session's web view with its tools", .serialized)
@MainActor
struct BrowserWorkspaceToolsTests {
  static let page = """
    <!doctype html><html><head><title>Tasks</title></head><body>
    <h1>Tasks</h1>
    <p>3 open</p>
    <label for="task">New task</label><input id="task" type="text">
    <label for="secret">Password</label><input id="secret" type="password">
    <button id="save" onclick="document.getElementById('count').textContent = String(Number(document.getElementById('count').textContent) + 1); console.error('saved ' + document.getElementById('task').value)">Save</button>
    <span id="count">0</span>
    <script>console.log('ready'); setTimeout(() => { throw new Error('boom') }, 0);</script>
    </body></html>
    """

  private func text(_ result: BrowserToolResult) -> String {
    result.content.compactMap {
      if case .text(let text) = $0 { return text }
      return nil
    }.joined()
  }

  private func object(_ result: BrowserToolResult) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text(result).utf8))
  }

  @Test("Open, read, click, fill, evaluate and read the console of a local preview")
  func localPreview() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()

    let opened = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    #expect(!opened.isError, "\(text(opened))")
    let status = try object(opened)
    #expect(status["title"] == "Tasks")
    #expect(status["loaded"] == true)
    #expect(workspace.isVisible(session))

    let snapshot = text(await workspace.run(tool: "page_read", arguments: [:], session: session))
    #expect(snapshot.contains("heading “Tasks” (level 1)"))
    #expect(snapshot.contains("button “Save”"))
    #expect(snapshot.contains("text “3 open”"))
    let saveReference = try #require(
      snapshot.split(separator: "\n").first { $0.contains("button “Save”") }?
        .split(separator: "]").first?.dropFirst())
    let fieldReference = try #require(
      snapshot.split(separator: "\n").first { $0.contains("textbox “New task”") }?
        .split(separator: "]").first?.dropFirst())

    let filled = await workspace.run(
      tool: "page_fill", arguments: ["ref": .string(String(fieldReference)), "value": "Ship"],
      session: session)
    #expect(!filled.isError, "\(text(filled))")
    let clicked = await workspace.run(
      tool: "page_click", arguments: ["ref": .string(String(saveReference))], session: session)
    #expect(text(clicked).hasPrefix("Clicked button “Save”"))

    let count = await workspace.run(
      tool: "page_evaluate", arguments: ["script": "document.getElementById('count').textContent"],
      session: session)
    #expect(text(count) == "\"1\"")
    let asynchronous = await workspace.run(
      tool: "page_evaluate",
      arguments: ["script": "await new Promise(r => setTimeout(r, 10)); return {n: 2}"],
      session: session)
    #expect(text(asynchronous) == #"{"n":2}"#)
    // A count of one is a number, not `true`; `return` in a string leaves an expression one.
    let one = await workspace.run(
      tool: "page_evaluate", arguments: ["script": "[document.querySelectorAll('h1').length, 0, true]"],
      session: session)
    #expect(text(one) == "[1,0,true]")
    let quoted = await workspace.run(
      tool: "page_evaluate", arguments: ["script": "'return policy'.length"], session: session)
    #expect(text(quoted) == "13")

    let console = text(await workspace.run(tool: "page_console", arguments: [:], session: session))
    #expect(console.contains("log: ready"))
    #expect(console.contains("error: saved Ship"))
    #expect(console.contains("Uncaught"))
    let errors = text(
      await workspace.run(tool: "page_console", arguments: ["level": "error"], session: session))
    #expect(!errors.contains("log: ready"))

    let browser = workspace.browser(for: session)
    let records = browser.actionLog.records
    #expect(records.contains { $0.tool == "page_click" && $0.decision == .automatic })
    #expect(records.contains { $0.tool == "page_fill" && $0.target.contains("← Ship") })
  }

  @Test("A value typed into a password field never reaches the trace")
  func passwordNotRecorded() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    let filled = await workspace.run(
      tool: "page_fill", arguments: ["selector": "#secret", "value": "hunter2"], session: session)
    #expect(!filled.isError, "\(text(filled))")
    let record = try #require(workspace.browser(for: session).actionLog.records.last)
    #expect(!record.target.contains("hunter2"))
    #expect(record.target.contains("••••••"))
  }

  @Test("Reloading shows what changed, and a stale reference says so")
  func reload() async throws {
    let server = try TestPageServer(pages: ["/": "<title>One</title><button>A</button>"])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    _ = await workspace.run(tool: "page_read", arguments: [:], session: session)
    server.setPage("/", "<title>Two</title><button>B</button>")
    let reloaded = try object(
      await workspace.run(tool: "tab_reload", arguments: [:], session: session))
    #expect(reloaded["title"] == "Two")
    let stale = await workspace.run(tool: "page_click", arguments: ["ref": "e1"], session: session)
    #expect(stale.isError)
    #expect(text(stale).contains("stale"))
  }

  @Test("A port nobody listens on says the server is not started")
  func serverNotStarted() async throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    // A port that was just freed: nothing listens there.
    let server = try TestPageServer(pages: [:])
    let url = server.url("/")
    server.stop()
    let opened = try object(
      await workspace.run(
        tool: "tab_open", arguments: ["url": .string(url.absoluteString)],
        session: session))
    #expect(opened["loaded"] == false)
    #expect(opened["error"]?.stringValue?.contains("Nothing is listening") == true)
    let tab = try #require(workspace.browser(for: session).activeTab)
    if case .serverNotStarted = tab.failure {
    } else {
      Issue.record("\(String(describing: tab.failure))")
    }
    #expect(tab.isRetrying)
    // Stopped, the tab tries a later address from the first attempt again.
    while tab.retryAttempt == 0 { try await Task.sleep(for: .milliseconds(100)) }
    tab.stopRetrying()
    #expect(tab.retryAttempt == 0)
  }

  @Test("A session sees its own tabs only, and an id from another is unknown")
  func isolation() async throws {
    let server = try TestPageServer(pages: ["/": "<title>A</title>"])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let first = SessionID()
    let second = SessionID()
    let opened = try object(
      await workspace.run(
        tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
        session: first))
    let id = try #require(opened["id"]?.stringValue)

    let list = try object(await workspace.run(tool: "tabs_list", arguments: [:], session: second))
    #expect(list == .array([]))
    let foreign = await workspace.run(
      tool: "tab_close", arguments: ["tab": .string(id)], session: second)
    #expect(foreign.isError)
    #expect(text(foreign).contains("No tab \(id) in this session"))
    let missing = await workspace.run(
      tool: "tab_close", arguments: ["tab": "00000000"], session: second)
    #expect(text(missing).replacingOccurrences(of: "00000000", with: id) == text(foreign))
    #expect(workspace.browser(for: first).tabs.count == 1)
  }

  @Test("Addresses an agent may not open are refused before any tab exists")
  func refusedAddresses() async {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    for address in ["javascript:alert(1)", "data:text/html,x", "mailto:a@b.c", ""] {
      let result = await workspace.run(
        tool: "tab_open", arguments: ["url": .string(address)], session: session)
      #expect(result.isError, "\(address)")
    }
    #expect(workspace.browser(for: session).tabs.isEmpty)
  }

  @Test("An agent that acts away from this Mac waits for the user, who can allow it for good")
  func asking() async throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(
      URL(string: "https://github.com/o/r/pull/1")!, in: session, openedBy: .agent, activate: false)
    let waiting = Task { @MainActor in
      await workspace.ask(
        .act(tool: "page_click", target: "button “Merge”", value: nil), tab: tab, in: session,
        grantKey: tab.origin?.grantKey)
    }
    while workspace.pendingRequests.isEmpty { await Task.yield() }
    let request = try #require(workspace.requests(for: session).first)
    #expect(request.site == "github.com")
    workspace.answer(request, with: .alwaysAllow)
    let outcome = await waiting.value
    #expect(outcome.isAllowed)
    #expect(workspace.grants == ["https://github.com"])
    #expect(workspace.pendingRequests.isEmpty)
    #expect(
      BrowserActionPolicy.decide(.act, url: tab.url, grants: workspace.permissions.grants) == .allow
    )
  }

  @Test("The ticket's tab follows the ticket, and cannot be closed")
  func ticketTab() async throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let repository = RepositoryWebAddress(forge: .github, host: "github.com", path: "o/r")
    workspace.updateTicket(stored: nil, branch: "feat/12-x", repository: repository, for: session)
    let browser = await workspace.restoredBrowser(for: session)
    let pinned = try #require(browser.ticketTab)
    #expect(pinned.url.absoluteString == "https://github.com/o/r/issues/12")
    #expect(browser.activeTab?.id == pinned.id)
    workspace.close(pinned.id, in: session)
    #expect(browser.ticketTab != nil)
    let closed = await workspace.run(
      tool: "tab_close", arguments: ["tab": .string(pinned.id.description)], session: session)
    #expect(closed.isError)
    workspace.updateTicket(
      stored: .removed, branch: "feat/12-x", repository: repository, for: session)
    #expect(browser.ticketTab == nil)
  }

  @Test("Tabs are kept, and come back in the same order with the same one in front")
  func persistence() async throws {
    let store = InMemoryBrowserStateStore()
    let session = SessionID()
    let first = BrowserWorkspace(stateStore: store, saveDelay: .zero)
    _ = await first.restoredBrowser(for: session)
    let a = first.open(URL(string: "http://localhost:1/a")!, in: session, openedBy: .user)
    first.open(URL(string: "http://localhost:1/b")!, in: session, openedBy: .agent, activate: false)
    first.browser(for: session).activate(a.id)
    await first.flush()

    let second = BrowserWorkspace(stateStore: store)
    let restored = await second.restoredBrowser(for: session)
    #expect(restored.tabs.map(\.url.path) == ["/a", "/b"])
    #expect(restored.activeTab?.url.path == "/a")
    #expect(restored.tabs.map(\.openedBy) == [.user, .agent])
    #expect(restored.isVisible)
    // A restored tab creates no page until it is wanted.
    #expect(restored.tabs.allSatisfy { !$0.isLoaded })
  }
}

@Suite("Opening local files")
@MainActor
struct BrowserFileTests {
  @Test("A local file opens and settles before the load timeout")
  func localFile() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeBrowserFile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let page = folder.appendingPathComponent("index.html")
    try Data("<!doctype html><title>File page</title><p>Hi</p>".utf8).write(to: page)
    let workspace = BrowserWorkspace()
    let result = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(page.path)], session: SessionID())
    let text = result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    // Settled, not given up on: the load timeout would return it still loading.
    #expect(text.contains("File page"), "\(text)")
    #expect(text.contains("\"loaded\":true"), "\(text)")
  }
}

@Suite("Acting on the page a tab holds, not the one it is heading to", .serialized)
@MainActor
struct BrowserCommittedPageTests {
  @Test("Nothing is done while a navigation is under way")
  func refusedWhileLoading() async throws {
    let server = try TestPageServer(pages: [
      "/": "<title>A</title><button>Go</button>", "/slow": "<title>B</title>",
    ])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    let tab = try #require(workspace.browser(for: session).activeTab)
    #expect(tab.committedURL?.path == "/")
    tab.load(server.url("/slow"))
    try await Task.sleep(for: .milliseconds(300))
    // The address already names the slow page; the document is still the first one.
    #expect(tab.url.path == "/slow")
    #expect(tab.committedURL?.path == "/")
    let evaluated = await workspace.run(
      tool: "page_evaluate", arguments: ["script": "document.title"], session: session)
    let text = evaluated.content.compactMap { if case .text(let t) = $0 { t } else { nil } }
      .joined()
    #expect(evaluated.isError || text == "\"B\"", "\(text)")
    #expect(text != "\"A\"")
  }

  @Test("A blank page a site opened is decided on that site")
  func blankPageOrigin() {
    let blank = URL(string: "about:blank")!
    let policy = { BrowserWorkspace.policyURL(committed: blank, reportedOrigin: $0) }
    #expect(policy("https://github.com").absoluteString == "https://github.com")
    #expect(
      BrowserActionPolicy.decide(.act, url: policy("https://github.com"), grants: []) == .ask)
    #expect(policy("null") == blank)
    #expect(policy(nil) == blank)
    #expect(BrowserActionPolicy.decide(.act, url: policy("null"), grants: []) == .allow)
    let page = URL(string: "http://localhost:5173/")!
    #expect(
      BrowserWorkspace.policyURL(committed: page, reportedOrigin: "https://github.com") == page)
  }

  @Test("The origin a page reports is the one the check compares with")
  func scriptOrigins() {
    let origin = { BrowserWorkspace.scriptOrigin(BrowserOrigin(url: URL(string: $0)!)!) }
    #expect(origin("https://github.com/o/r") == "https://github.com")
    #expect(origin("http://localhost:5173/x") == "http://localhost:5173")
    #expect(origin("https://example.com:443/") == "https://example.com")
    #expect(origin("http://[::1]:3000/") == "http://[::1]:3000")
    #expect(
      BrowserWorkspace.scriptOrigin(BrowserOrigin(url: URL(fileURLWithPath: "/tmp/a.html"))!) == nil
    )
  }
}

@Suite("Signing in from the web view")
@MainActor
struct BrowserSignInTests {
  @Test("Pages see Safari, so sign-in pages do not refuse the web view")
  func userAgent() async throws {
    let server = try TestPageServer(pages: ["/": "<title>UA</title>"])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    let agent = await workspace.run(
      tool: "page_evaluate", arguments: ["script": "navigator.userAgent"], session: session)
    let text = agent.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    #expect(text.contains("Safari/605.1.15"), "\(text)")
    #expect(text.contains("Version/"), "\(text)")
  }

  @Test("A window that closes itself, as a sign-in pop-up does, closes its tab")
  func popupCloses() async throws {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let tab = workspace.open(URL(string: "about:blank")!, in: session, openedBy: .user)
    #expect(workspace.browser(for: session).tabs.count == 1)
    tab.didCloseWindow?()
    #expect(workspace.browser(for: session).tabs.isEmpty)
  }
}
