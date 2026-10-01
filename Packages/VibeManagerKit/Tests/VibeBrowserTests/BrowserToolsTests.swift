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

  /// The test server, reached through an address the policy holds for another machine: an
  /// IPv4-mapped IPv6 address is the loopback to the network, not to `BrowserOrigin.isLocal`.
  private func remoteURL(_ server: TestPageServer) -> URL {
    URL(string: "http://[::ffff:127.0.0.1]:\(server.port)/")!
  }

  private func first(_ result: BrowserToolResult) throws -> JSONValue {
    guard case .array(let items) = try object(result), let item = items.first else {
      throw BrowserToolFailure("No tab listed: \(text(result))")
    }
    return item
  }

  private func answerNext(
    _ workspace: BrowserWorkspace, in session: SessionID, with answer: BrowserPermissionAnswer
  ) async throws -> BrowserPermissionRequest {
    while workspace.requests(for: session).isEmpty { await Task.yield() }
    let request = try #require(workspace.requests(for: session).first)
    workspace.answer(request, with: answer)
    return request
  }

  @Test("A site away from this Mac is read only once the user allows it, for the session (#239)")
  func remoteReadIsAsked() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()

    // Opened in the background as asked, it comes to the front all the same, without its title.
    let opened = try object(
      await workspace.run(
        tool: "tab_open",
        arguments: ["url": .string(remoteURL(server).absoluteString), "activate": false],
        session: session))
    #expect(opened["loaded"] == true)
    #expect(opened["inFront"] == true)
    #expect(opened["title"] == "")
    let tabID = try #require(opened["id"]?.stringValue)
    #expect(workspace.browser(for: session).activeTab?.id.description == tabID)
    let listed = try first(await workspace.run(tool: "tabs_list", arguments: [:], session: session))
    #expect(listed["title"] == "")
    #expect(listed["readable"] == false)

    // Each tool that reads asks first.
    for tool in ["page_read", "page_screenshot", "page_console"] {
      let reader = SessionID()
      _ = await workspace.run(
        tool: "tab_open", arguments: ["url": .string(remoteURL(server).absoluteString)],
        session: reader)
      let refused = Task { @MainActor in
        await workspace.run(tool: tool, arguments: [:], session: reader)
      }
      let question = try await answerNext(workspace, in: reader, with: .deny)
      #expect(question.kind == .read(tool: tool))
      #expect(question.grantKey == nil)
      let refusal = await refused.value
      #expect(refusal.isError)
      #expect(!text(refusal).contains("Tasks"))
    }

    // Allowed: read now, and for the rest of the session without asking.
    let allowed = Task { @MainActor in
      await workspace.run(tool: "page_read", arguments: ["mode": "text"], session: session)
    }
    _ = try await answerNext(workspace, in: session, with: .allowOnce)
    #expect(text(await allowed.value).contains("3 open"))
    let again = await workspace.run(
      tool: "page_read", arguments: ["mode": "text"], session: session)
    #expect(text(again).contains("3 open"))
    let console = await workspace.run(tool: "page_console", arguments: [:], session: session)
    #expect(!console.isError)
    #expect(workspace.pendingRequests.isEmpty)
    let relisted = try first(
      await workspace.run(tool: "tabs_list", arguments: [:], session: session))
    #expect(relisted["title"] == "Tasks")
    #expect(relisted["readable"] == true)

    // Another session asks for itself; an archived session forgets what it was allowed.
    let other = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(remoteURL(server).absoluteString)],
      session: other)
    let otherRead = Task { @MainActor in
      await workspace.run(tool: "page_read", arguments: [:], session: other)
    }
    _ = try await answerNext(workspace, in: other, with: .deny)
    #expect(await otherRead.value.isError)
    workspace.release(session)
    #expect(workspace.browser(for: session).readableSites.isEmpty)

    let records = workspace.browser(for: other).actionLog.records
    #expect(records.contains { $0.tool == "page_read" && $0.decision == .denied })
    #expect(
      workspace.browser(for: session).actionLog.records.contains {
        $0.tool == "page_read" && $0.decision == .confirmed
      })
  }

  @Test("A page of this Mac is read without a question, and may wait in the background")
  func localReadIsFree() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    let opened = try object(
      await workspace.run(
        tool: "tab_open",
        arguments: ["url": .string(server.url("/").absoluteString), "activate": false],
        session: session))
    #expect(opened["inFront"] == nil)
    #expect(opened["title"] == "Tasks")
    #expect(workspace.browser(for: session).activeTab?.id.description != opened["id"]?.stringValue)
    let read = await workspace.run(tool: "page_read", arguments: [:], session: session)
    #expect(text(read).contains("Tasks"))
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("A site always allowed to act on is read without a question")
  func grantedSiteIsRead() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(remoteURL(server).absoluteString)],
      session: session)
    // The site as WebKit committed it: the address comes back normalized.
    let site = try #require(workspace.browser(for: session).activeTab?.committedOrigin)
    #expect(!site.isLocal)
    workspace.permissions.grant(site.grantKey)
    let read = await workspace.run(tool: "page_read", arguments: ["mode": "text"], session: session)
    #expect(text(read).contains("3 open"))
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("A tab the agent did not open shows only its site, until the site may be read")
  func userTabsAreCutToTheirSite() {
    #expect(
      BrowserWorkspace.siteAddress(URL(string: "https://github.com/acme/secret/issues/1?q=x")!)
        == "https://github.com/")
    #expect(
      BrowserWorkspace.siteAddress(URL(string: "http://[::1]:3000/a")!) == "http://[::1]:3000/")
    #expect(BrowserWorkspace.siteAddress(URL(string: "about:blank")!) == "about:")
  }

  @Test("No answer shows the whole address or the title of a site that may not be read (#239)")
  func nothingLeaksWithoutAnAnswer() async throws {
    let secret = "/secret?token=abc"
    let server = try TestPageServer(pages: ["/": Self.page, secret: Self.page])
    defer { server.stop() }
    let remoteSecret = URL(string: "http://[::ffff:127.0.0.1]:\(server.port)\(secret)")!
    server.setRedirect("/r", to: remoteSecret.absoluteString)
    server.setPage(
      "/link", "<title>Link</title><a id=\"go\" href=\"\(remoteSecret.absoluteString)\">go</a>")
    let workspace = BrowserWorkspace()
    let session = SessionID()

    // The user's own tab, signed in: listed and reloaded, it shows only its site.
    let user = workspace.open(remoteSecret, in: session, openedBy: .user)
    await user.waitUntilSettled(timeout: .seconds(15))
    let listed = try first(await workspace.run(tool: "tabs_list", arguments: [:], session: session))
    #expect(listed["url"]?.stringValue?.contains("token") == false)
    #expect(listed["title"] == "")
    let reloaded = await workspace.run(
      tool: "tab_reload", arguments: ["tab": .string(user.id.description)], session: session)
    #expect(!text(reloaded).contains("token"))
    #expect(!text(reloaded).contains("Tasks"))

    // A redirection from a local address the agent gave: the address it ends on is not shown.
    let redirected = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/r").absoluteString)],
      session: session)
    #expect(!text(redirected).contains("token"), "\(text(redirected))")
    let all = try object(await workspace.run(tool: "tabs_list", arguments: [:], session: session))
    #expect(!all.jsonText.contains("token"))

    // A click on a local page that goes to a site away from this Mac says where only by its site.
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/link").absoluteString)],
      session: session)
    let clicked = await workspace.run(
      tool: "page_click", arguments: ["selector": "#go"], session: session)
    #expect(!clicked.isError, "\(text(clicked))")
    #expect(!text(clicked).contains("token"), "\(text(clicked))")
  }

  @Test("A page the agent drives never goes to a site away from this Mac behind (#239)")
  func remoteLoadsComeForward() async throws {
    let server = try TestPageServer(pages: ["/": Self.page, "/b": "<title>B</title>"])
    defer { server.stop() }
    server.setRedirect("/r", to: remoteURL(server).absoluteString)
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let browser = workspace.browser(for: session)
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)

    // A local address, opened behind, that redirects away from this Mac.
    let redirected = try object(
      await workspace.run(
        tool: "tab_open",
        arguments: ["url": .string(server.url("/r").absoluteString), "activate": false],
        session: session))
    #expect(redirected["inFront"] == true)
    #expect(browser.activeTab?.id.description == redirected["id"]?.stringValue)

    // A local page left behind, sent away by a script the agent ran.
    let front = try object(
      await workspace.run(
        tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
        session: session))
    let behind = try object(
      await workspace.run(
        tool: "tab_open",
        arguments: ["url": .string(server.url("/b").absoluteString), "activate": false],
        session: session))
    let behindID = try #require(behind["id"]?.stringValue)
    #expect(browser.activeTab?.id.description == front["id"]?.stringValue)
    let script = "location.href = '\(remoteURL(server).absoluteString)'; 1"
    _ = await workspace.run(
      tool: "page_evaluate", arguments: ["tab": .string(behindID), "script": .string(script)],
      session: session)
    let tab = try #require(browser.allTabs.first { $0.id.description == behindID })
    await tab.waitUntilSettled(timeout: .seconds(15))
    #expect(browser.activeTab?.id.description == behindID)

    // A tab behind sent away by tab_navigate.
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/").absoluteString)],
      session: session)
    let navigated = try object(
      await workspace.run(
        tool: "tab_navigate",
        arguments: [
          "tab": .string(behindID), "url": .string(remoteURL(server).absoluteString),
        ], session: session))
    #expect(navigated["inFront"] == true)
    #expect(browser.activeTab?.id.description == behindID)
  }

  @Test("A site the user refused to let the session read is not asked again (#239)")
  func refusalIsKept() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(remoteURL(server).absoluteString)],
      session: session)
    let asked = Task { @MainActor in
      await workspace.run(tool: "page_read", arguments: [:], session: session)
    }
    _ = try await answerNext(workspace, in: session, with: .deny)
    #expect(await asked.value.isError)
    let again = await workspace.run(tool: "page_read", arguments: [:], session: session)
    #expect(again.isError)
    #expect(text(again).contains("refused"))
    #expect(workspace.pendingRequests.isEmpty)
  }

  @Test("A capture asks for the sites of the frames it would show (#239)", .timeLimit(.minutes(1)))
  func framesAreAsked() async throws {
    let server = try TestPageServer(pages: ["/": Self.page])
    defer { server.stop() }
    let remote = remoteURL(server)
    server.setPage(
      "/framed",
      "<title>Framed</title><iframe src=\"\(remote.absoluteString)\" width=300 height=200>"
        + "</iframe>")
    let workspace = BrowserWorkspace()
    let session = SessionID()
    _ = await workspace.run(
      tool: "tab_open", arguments: ["url": .string(server.url("/framed").absoluteString)],
      session: session)
    let ended = Flag()
    let capture = Task { @MainActor in
      let result = await workspace.run(tool: "page_screenshot", arguments: [:], session: session)
      ended.isSet = true
      return result
    }
    // Either a question comes, or the capture ends without one: the second is the failure.
    while workspace.requests(for: session).isEmpty, !ended.isSet { await Task.yield() }
    let question = try #require(
      workspace.requests(for: session).first, "The capture was taken without a question.")
    workspace.answer(question, with: .deny)
    #expect(question.kind == .read(tool: "page_screenshot"))
    // The frame's site, as WebKit wrote its address — not the local page's.
    #expect(question.site.hasPrefix("[::ffff:"))
    #expect(question.site.hasSuffix(":\(server.port)"))
    #expect(await capture.value.isError)
  }

  @Test("The sites always allowed are listed once the store has read them, after launch (#239)")
  func grantsListedOnceLoaded() async {
    let store = SlowPermissionStore()
    let workspace = BrowserWorkspace(permissions: store)
    #expect(workspace.grants.isEmpty)
    store.finishLoading(with: ["https://github.com"])
    await workspace.permissionsLoaded()
    #expect(workspace.grants == ["https://github.com"])
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

/// A store that reads its sites in the background, as the keychain's does.
@MainActor
private final class SlowPermissionStore: BrowserPermissionStore {
  private(set) var grants: Set<String> = []
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var isLoaded = false

  func grant(_ key: String) { grants.insert(key) }
  func revoke(_ key: String) { grants.remove(key) }

  func loaded() async {
    guard !isLoaded else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func finishLoading(with sites: Set<String>) {
    grants = sites
    isLoaded = true
    for continuation in waiting { continuation.resume() }
    waiting = []
  }
}

@MainActor
private final class Flag {
  var isSet = false
}
