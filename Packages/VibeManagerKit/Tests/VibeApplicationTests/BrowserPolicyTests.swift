import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("What an agent may do in a web view without asking")
struct BrowserPolicyTests {
  private func decide(_ action: BrowserActionClass, _ address: String, grants: Set<String> = [])
    -> BrowserActionDecision
  {
    BrowserActionPolicy.decide(action, url: URL(string: address), grants: grants)
  }

  @Test(
    "Acting on this Mac is free",
    arguments: [
      "http://localhost:5173/", "https://localhost/", "http://app.localhost:3000/x",
      "http://127.0.0.1:8080", "http://127.1/", "http://[::1]:4000/", "file:///tmp/index.html",
      "http://LOCALHOST.:80/",
    ])
  func localIsFree(address: String) {
    #expect(decide(.act, address) == .allow)
  }

  @Test(
    "Acting anywhere else is asked",
    arguments: [
      "https://github.com/o/r/pull/1", "http://0.0.0.0:8000/", "http://192.168.1.10/",
      "http://my-mac.local/", "http://evil.localhost.com/", "http://localhost@evil.com/",
      "https://xn--80ak6aa92e.com/", "http://127.0.0.1.nip.io/",
    ])
  func elsewhereIsAsked(address: String) {
    #expect(decide(.act, address) == .ask)
  }

  @Test("An \"Always Allow\" covers its site, and only its site")
  func grants() {
    let grants: Set<String> = ["https://github.com"]
    #expect(decide(.act, "https://github.com/o/r", grants: grants) == .allow)
    #expect(decide(.act, "https://gist.github.com/x", grants: grants) == .ask)
    #expect(decide(.act, "http://github.com/o/r", grants: grants) == .ask)
    #expect(decide(.act, "https://github.com:8443/o/r", grants: grants) == .ask)
  }

  @Test("Reading is free everywhere")
  func reading() {
    #expect(decide(.read, "https://mail.example.com/inbox") == .allow)
  }

  @Test("A tab may go to the web and to local files, never to code in an address")
  func navigation() {
    #expect(decide(.navigate, "https://github.com") == .allow)
    #expect(decide(.navigate, "file:///tmp/a.html") == .allow)
    #expect(decide(.navigate, "about:blank") == .allow)
    #expect(decide(.navigate, "mailto:someone@example.com") == .ask)
    #expect(decide(.navigate, "vscode://file/tmp") == .ask)
    if case .deny = decide(.navigate, "javascript:alert(1)") {} else { Issue.record("allowed") }
    if case .deny = decide(.navigate, "data:text/html,<b>x</b>") {} else { Issue.record("allowed") }
  }

  @Test("A site is named as a person reads it")
  func origins() {
    #expect(BrowserOrigin(url: URL(string: "https://github.com/x")!)?.description == "github.com")
    #expect(
      BrowserOrigin(url: URL(string: "http://localhost:5173/x")!)?.description == "localhost:5173")
    #expect(
      BrowserOrigin(url: URL(string: "https://github.com:443/x")!)?.grantKey
        == "https://github.com")
    #expect(BrowserOrigin(url: URL(string: "http://[::1]:3000/")!)?.description == "[::1]:3000")
    #expect(BrowserOrigin(url: URL(string: "about:blank")!) == nil)
  }
}

@Suite("Knowing which session a process on the channel belongs to")
struct BrowserChannelAuthorizerTests {
  private let a = SessionID()
  private let b = SessionID()

  private func time(_ seconds: UInt64) -> ProcessStartTime {
    ProcessStartTime(seconds: seconds, microseconds: 0)
  }

  private func entry(_ pid: Int32, parent: Int32, at seconds: UInt64) -> ProcessLineageEntry {
    ProcessLineageEntry(
      processIdentifier: pid, parentProcessIdentifier: parent, startedAt: time(seconds))
  }

  private var sessions: [SessionProcess] {
    [
      SessionProcess(sessionID: a, processIdentifier: 100, startedAt: time(10)),
      SessionProcess(sessionID: b, processIdentifier: 200, startedAt: time(20)),
    ]
  }

  @Test("The agent's child and grandchild belong to its session")
  func descendants() {
    let bridge = [entry(101, parent: 100, at: 11), entry(100, parent: 50, at: 10)]
    #expect(BrowserChannelAuthorizer.session(of: bridge, among: sessions) == a)
    let script = [
      entry(302, parent: 301, at: 25), entry(301, parent: 200, at: 21),
      entry(200, parent: 50, at: 20), entry(50, parent: 1, at: 1),
    ]
    #expect(BrowserChannelAuthorizer.session(of: script, among: sessions) == b)
  }

  @Test("A process outside every session's tree is refused")
  func stranger() {
    let lineage = [entry(900, parent: 800, at: 30), entry(800, parent: 1, at: 2)]
    #expect(BrowserChannelAuthorizer.session(of: lineage, among: sessions) == nil)
    #expect(BrowserChannelAuthorizer.session(of: [], among: sessions) == nil)
  }

  @Test("A number given again to another process does not inherit the session")
  func reusedIdentifier() {
    // Process 100 is not the session's agent: it started later than the one recorded.
    let lineage = [entry(101, parent: 100, at: 40), entry(100, parent: 1, at: 39)]
    #expect(BrowserChannelAuthorizer.session(of: lineage, among: sessions) == nil)
  }

  @Test("A parent that started after its child breaks the chain there")
  func brokenChain() {
    let lineage = [entry(101, parent: 100, at: 11), entry(100, parent: 50, at: 12)]
    let late = [SessionProcess(sessionID: a, processIdentifier: 100, startedAt: time(12))]
    #expect(BrowserChannelAuthorizer.session(of: lineage, among: late) == nil)
  }

  @Test("The agent itself belongs to its session")
  func agentItself() {
    #expect(
      BrowserChannelAuthorizer.session(of: [entry(200, parent: 50, at: 20)], among: sessions) == b)
  }
}

@Suite("The trace of what agents did in a web view")
struct BrowserActionLogTests {
  private func record(_ tool: String, at seconds: TimeInterval, target: String = "")
    -> BrowserActionRecord
  {
    BrowserActionRecord(
      date: Date(timeIntervalSince1970: seconds), tool: tool, origin: "localhost:5173",
      target: target, decision: .automatic, succeeded: true)
  }

  @Test("Reads in a row are counted as one entry, actions never")
  func grouping() {
    var log = BrowserActionLog()
    log.append(record("page_read", at: 1), isRead: true)
    log.append(record("page_read", at: 2), isRead: true)
    log.append(record("page_click", at: 3), isRead: false)
    log.append(record("page_click", at: 4), isRead: false)
    #expect(log.records.map(\.tool) == ["page_read", "page_click", "page_click"])
    #expect(log.records[0].count == 2)
    #expect(log.records[0].date == Date(timeIntervalSince1970: 2))
  }

  @Test("The trace keeps the last two hundred entries")
  func bounded() {
    var log = BrowserActionLog()
    for index in 0..<250 {
      log.append(record("page_click", at: TimeInterval(index)), isRead: false)
    }
    #expect(log.records.count == 200)
    #expect(log.records.first?.date == Date(timeIntervalSince1970: 50))
  }

  @Test("A value typed into a sensitive field is never kept, others are cut short")
  func values() {
    #expect(BrowserActionLog.recordedValue("hunter2", isSensitive: true) == "••••••")
    let long = String(repeating: "a", count: 100)
    #expect(BrowserActionLog.recordedValue(long, isSensitive: false).count == 81)
    #expect(BrowserActionLog.recordedValue("two\nlines", isSensitive: false) == "two lines")
  }
}

@Suite("Where the web view goes as the window narrows")
struct BrowserLayoutPolicyTests {
  private func columns(_ width: Double, browser: Bool) -> WorkspaceColumns {
    WorkspaceLayoutPolicy.resolve(
      windowWidth: width, intent: WorkspaceLayout(), isBrowserRequested: browser)
  }

  @Test("Without the web view, nothing changes")
  func unchanged() {
    #expect(
      columns(1_100, browser: false)
        == WorkspaceColumns(isSidebarVisible: true, isInspectorVisible: true))
    #expect(columns(900, browser: false).isInspectorVisible == false)
  }

  @Test("The inspector folds first, then the sidebar, then the two take turns")
  func order() {
    #expect(
      columns(1_700, browser: true)
        == WorkspaceColumns(
          isSidebarVisible: true, isInspectorVisible: true, browser: .beside))
    #expect(
      columns(1_400, browser: true)
        == WorkspaceColumns(
          isSidebarVisible: true, isInspectorVisible: false, browser: .beside))
    #expect(
      columns(1_000, browser: true)
        == WorkspaceColumns(
          isSidebarVisible: false, isInspectorVisible: false, browser: .beside))
    #expect(
      columns(850, browser: true)
        == WorkspaceColumns(
          isSidebarVisible: false, isInspectorVisible: false, browser: .alternating))
  }

  @Test("An unmeasured window shows the web view beside the terminal")
  func unmeasured() {
    #expect(columns(0, browser: true).browser == .beside)
  }

  @Test("The web view's width is bounded, and read back from a stored layout")
  func width() throws {
    #expect(WorkspaceLayout(browserWidth: 10).browserWidth == 380)
    #expect(WorkspaceLayout(browserWidth: .nan).browserWidth == 520)
    let data = Data(#"{"browserWidth": 700}"#.utf8)
    #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: data).browserWidth == 700)
    let old = Data(#"{"isSidebarVisible": false}"#.utf8)
    #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: old).browserWidth == 520)
  }
}
