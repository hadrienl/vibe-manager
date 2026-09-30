import AppKit
import Foundation
import VibeApplication
import VibeDomain
import WebKit

extension BrowserWorkspace: BrowserToolRunning {
  static let defaultReadLimit = 20_000
  static let maximumReadLimit = 100_000
  static let evaluateLimit = 20_000
  static let screenshotSide: CGFloat = 1_568

  public func run(tool name: String, arguments: JSONValue, session id: SessionID) async
    -> BrowserToolResult
  {
    guard let tool = BrowserToolCatalog.tool(named: name) else {
      return .error("Unknown tool \(name).")
    }
    let browser = await restoredBrowser(for: id)
    do {
      switch name {
      case "tabs_list":
        let result = listTabs(browser)
        record(
          tool, in: browser, tab: nil, target: "\(browser.allTabs.count) tabs", decision: .automatic
        )
        return result
      case "tab_open":
        return try await openTab(arguments, browser: browser, tool: tool)
      default:
        let tab = try target(arguments, in: browser)
        return try await run(tool, on: tab, arguments: arguments, browser: browser)
      }
    } catch let failure as BrowserToolFailure {
      record(tool, in: browser, tab: nil, target: "", decision: .automatic, succeeded: false)
      return .error(failure.message)
    } catch {
      record(tool, in: browser, tab: nil, target: "", decision: .automatic, succeeded: false)
      return .error(Self.describe(error))
    }
  }

  private func run(
    _ tool: BrowserToolCatalog.Tool, on tab: BrowserTabModel, arguments: JSONValue,
    browser: SessionBrowser
  ) async throws -> BrowserToolResult {
    switch tool.name {
    case "tab_navigate":
      let url = try Self.address(arguments["url"]?.stringValue)
      guard !tab.isPinnedTicket else {
        throw BrowserToolFailure(
          "The ticket's tab stays on the ticket: open the address in a new tab with tab_open.")
      }
      // A page away from this Mac is never loaded out of sight (#239).
      let broughtForward = Self.isRemote(url) && browser.activeTab?.id != tab.id
      if broughtForward { browser.activate(tab.id) }
      willAct(on: tab)
      defer { didAct(on: tab) }
      tab.ensureWebView()
      tab.load(url)
      await tab.waitUntilSettled(timeout: Self.loadTimeout)
      record(
        tool, in: browser, tab: tab, target: url.absoluteString, decision: .automatic,
        succeeded: tab.failure == nil)
      return status(of: tab, in: browser, broughtForward: broughtForward)
    case "tab_reload":
      willAct(on: tab)
      defer { didAct(on: tab) }
      if tab.isLoaded {
        tab.reload(ignoringCache: arguments["ignoreCache"]?.boolValue ?? false)
      } else {
        tab.ensureWebView()
      }
      await tab.waitUntilSettled(timeout: Self.loadTimeout)
      record(
        tool, in: browser, tab: tab, target: "", decision: .automatic,
        succeeded: tab.failure == nil)
      return status(of: tab, in: browser)
    case "tab_activate":
      browser.activate(tab.id)
      tab.ensureWebView()
      record(tool, in: browser, tab: tab, target: tab.displayTitle, decision: .automatic)
      return .text("Tab \(tab.id) is in front.")
    case "tab_close":
      guard !tab.isPinnedTicket else {
        throw BrowserToolFailure("The ticket's tab is pinned and cannot be closed.")
      }
      close(tab.id, in: browser.sessionID)
      record(tool, in: browser, tab: tab, target: tab.displayTitle, decision: .automatic)
      return .text("Tab \(tab.id) is closed.")
    case "page_read":
      let webView = try await ready(tab)
      let read = try await mayRead(tool, tab, webView: webView, browser: browser)
      let limit = min(
        max(arguments["maxChars"]?.intValue ?? Self.defaultReadLimit, 1_000), Self.maximumReadLimit)
      let mode = arguments["mode"]?.stringValue == "text" ? "text" : "snapshot"
      // The page is asked for its origin in the same turn as the read: the web process may have
      // committed a navigation the application has not heard of yet.
      let text = try await configuration.callAgent(
        "if (expected !== null && location.origin !== expected) { throw new Error('The page changed before it could be read: nothing was read.'); } return window.__vibeAgent.\(mode)(limit);",
        arguments: [
          "limit": limit, "expected": read.origin.flatMap { Self.scriptOrigin($0) } ?? NSNull(),
        ], in: webView)
      try stillOn(read, tab)
      record(tool, in: browser, tab: tab, target: mode, decision: read.decision)
      return .text((text as? String) ?? "")
    case "page_screenshot":
      let webView = try await ready(tab)
      let read = try await mayRead(tool, tab, webView: webView, browser: browser)
      let png = try await Self.screenshot(of: webView)
      try stillOn(read, tab)
      record(tool, in: browser, tab: tab, target: "", decision: read.decision)
      return BrowserToolResult(content: [.image(png, mimeType: "image/png")])
    case "page_console":
      // A page that failed to load still has a console worth reading: it says why.
      let webView = tab.isLoaded ? tab.ensureWebView() : try await ready(tab)
      let read = try await mayRead(tool, tab, webView: webView, browser: browser)
      try stillOn(read, tab)
      let minimum =
        arguments["level"]?.stringValue.flatMap(BrowserConsoleEntry.Level.init) ?? .debug
      let limit = min(max(arguments["limit"]?.intValue ?? 200, 1), 200)
      let entries = tab.console.entries.filter { $0.level >= minimum }.suffix(limit)
      record(tool, in: browser, tab: tab, target: "\(entries.count) messages", decision: read.decision)
      guard !entries.isEmpty else { return .text("The console is empty since the page loaded.") }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withTime, .withColonSeparatorInTime]
      return .text(
        entries.map { "[\(formatter.string(from: $0.date))] \($0.level.rawValue): \($0.text)" }
          .joined(separator: "\n"))
    case "page_click", "page_fill", "page_evaluate":
      return try await act(tool, on: tab, arguments: arguments, browser: browser)
    default:
      throw BrowserToolFailure("Unknown tool \(tool.name).")
    }
  }

  // MARK: - Acting

  private func act(
    _ tool: BrowserToolCatalog.Tool, on tab: BrowserTabModel, arguments: JSONValue,
    browser: SessionBrowser
  ) async throws -> BrowserToolResult {
    let webView = try await ready(tab)
    // What may be done is decided on the document the page holds, never on where a navigation is
    // heading: until it commits, the page is still the previous site's, with its cookies.
    guard !tab.isLoading, let committed = tab.committedURL else {
      throw BrowserToolFailure(
        "The page is still loading: nothing was done. Wait for it with page_read, then try again.")
    }
    // A blank page a site opened holds that site's origin, and reaches its opener: acting there is
    // acting as the user on that site. The page is asked which origin it has.
    var reported: String?
    if BrowserOrigin(url: committed) == nil {
      reported =
        try await configuration.callAgent(
          "return location.origin;", arguments: [:], in: webView) as? String
    }
    let policyURL = Self.policyURL(committed: committed, reportedOrigin: reported)
    let site = BrowserOrigin(url: policyURL)
    let target = Self.elementTarget(arguments)
    var description = ""
    var value: String?
    switch tool.name {
    case "page_evaluate":
      guard let script = arguments["script"]?.stringValue, !script.isEmpty else {
        throw BrowserToolFailure("page_evaluate needs a script.")
      }
      description = BrowserActionLog.shortened(script, to: BrowserActionLog.scriptLimit)
    default:
      guard !target.isEmpty else {
        throw BrowserToolFailure("Name the element with ref or selector.")
      }
      let inspected = try await configuration.callAgent(
        "return window.__vibeAgent.inspect(target);", arguments: ["target": target], in: webView)
      let fields = inspected as? [String: Any]
      description = fields?["description"] as? String ?? "element"
      if tool.name == "page_fill" {
        guard let typed = arguments["value"]?.stringValue else {
          throw BrowserToolFailure("page_fill needs a value.")
        }
        value = BrowserActionLog.recordedValue(
          typed, isSensitive: fields?["sensitive"] as? Bool ?? false)
      }
    }

    let decision: BrowserActionRecord.Decision
    switch BrowserActionPolicy.decide(.act, url: policyURL, grants: permissions.grants) {
    case .allow:
      let isLocal = site?.isLocal ?? true
      decision = isLocal ? .automatic : .always
    case .deny(let reason):
      throw BrowserToolFailure(reason)
    case .ask:
      tab.isAgentActing = true
      let outcome = await ask(
        .act(tool: tool.name, target: description, value: value), tab: tab,
        in: browser.sessionID, grantKey: site?.grantKey)
      tab.isAgentActing = false
      switch outcome {
      case .allowed(let always):
        decision = always ? .always : .confirmed
      case .denied:
        record(
          tool, in: browser, tab: tab, target: Self.trace(description, value), decision: .denied,
          succeeded: false)
        return .error(
          "The user refused: nothing was done on \(site?.description ?? "the page").")
      case .expired:
        record(
          tool, in: browser, tab: tab, target: Self.trace(description, value), decision: .expired,
          succeeded: false)
        return .error(
          "Nobody answered within two minutes: nothing was done. Ask the user, then try again.")
      }
    }

    // What was allowed was this site. A page that moved meanwhile — while the question was on
    // screen, or since the element was looked up — is not acted on.
    guard !tab.isLoading,
      tab.committedURL.flatMap(BrowserOrigin.init(url:)) == BrowserOrigin(url: committed)
    else {
      record(
        tool, in: browser, tab: tab, target: Self.trace(description, value), decision: decision,
        succeeded: false)
      throw BrowserToolFailure(
        "The page changed before the action could run: nothing was done. Read it again.")
    }
    willAct(on: tab)
    defer { didAct(on: tab) }
    let before = tab.url
    do {
      // Checked once more inside the page, in the same turn as the action: the web process may
      // have committed a navigation the application has not heard of yet.
      if let expected = site.flatMap(Self.scriptOrigin) {
        _ = try await configuration.callAgent(
          "if (location.origin !== expected) { throw new Error('The page changed before the action could run: nothing was done.'); } return true;",
          arguments: ["expected": expected], in: webView)
      }
      let result: BrowserToolResult
      switch tool.name {
      case "page_click":
        let clicked = try await configuration.callAgent(
          "return window.__vibeAgent.click(target);", arguments: ["target": target], in: webView)
        try? await Task.sleep(for: .milliseconds(300))
        await tab.waitUntilSettled(timeout: .seconds(5))
        let moved = tab.url != before ? " The page went to \(tab.url.absoluteString)." : ""
        result = .text("Clicked \((clicked as? String) ?? description).\(moved)")
      case "page_fill":
        let filled = try await configuration.callAgent(
          "return window.__vibeAgent.fill(target, value, submit);",
          arguments: [
            "target": target, "value": arguments["value"]?.stringValue ?? "",
            "submit": arguments["submit"]?.boolValue ?? false,
          ], in: webView)
        let name = ((filled as? [String: Any])?["description"] as? String) ?? description
        if arguments["submit"]?.boolValue == true {
          await tab.waitUntilSettled(timeout: .seconds(5))
        }
        result = .text("Filled \(name).")
      default:
        let script = arguments["script"]?.stringValue ?? ""
        let value = try await Self.evaluate(script, in: webView)
        let text = JSONValue(any: value).jsonText
        result = .text(
          text.count > Self.evaluateLimit
            ? String(text.prefix(Self.evaluateLimit)) + "\n[truncated]" : text)
      }
      record(
        tool, in: browser, tab: tab, target: Self.trace(description, value), decision: decision)
      return result
    } catch {
      record(
        tool, in: browser, tab: tab, target: Self.trace(description, value), decision: decision,
        succeeded: false)
      throw BrowserToolFailure(Self.describe(error))
    }
  }

  /// The address an action is decided on: the document's own, or — for a page without an origin
  /// of its own, as a blank page a site opened — the web origin the page says it has.
  static func policyURL(committed: URL, reportedOrigin: String?) -> URL {
    guard BrowserOrigin(url: committed) == nil, let reportedOrigin,
      let url = URL(string: reportedOrigin), let origin = BrowserOrigin(url: url),
      scriptOrigin(origin) != nil
    else { return committed }
    return url
  }

  /// `location.origin` as a page reports it for an origin: no default port, IPv6 in brackets. `nil`
  /// for local files, whose origin a page reports as opaque.
  static func scriptOrigin(_ origin: BrowserOrigin) -> String? {
    guard origin.scheme == "http" || origin.scheme == "https" else { return nil }
    let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
    let defaultPort = origin.scheme == "http" ? 80 : 443
    guard let port = origin.port, port != defaultPort else { return "\(origin.scheme)://\(host)" }
    return "\(origin.scheme)://\(host):\(port)"
  }

  /// An expression is evaluated as it is; what does not parse as one — a body with `return` or
  /// `await` — runs as an async function. A syntax error is raised before anything runs, so the
  /// script never runs twice.
  static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
    do {
      return try await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
    } catch let error as NSError where isSyntaxError(error) {
      return try await webView.callAsyncJavaScript(
        script, arguments: [:], in: nil, contentWorld: .page)
    }
  }

  private static func isSyntaxError(_ error: NSError) -> Bool {
    let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
    return message.hasPrefix("SyntaxError")
  }

  // MARK: - Opening

  private func openTab(
    _ arguments: JSONValue, browser: SessionBrowser, tool: BrowserToolCatalog.Tool
  ) async throws -> BrowserToolResult {
    let url = try Self.address(arguments["url"]?.stringValue)
    let asked = arguments["activate"]?.boolValue ?? true
    // A page away from this Mac is never opened out of sight (#239): the user sees what the agent
    // loads with their cookies. A preview on this Mac may still wait behind.
    let broughtForward = !asked && Self.isRemote(url)
    let tab = open(url, in: browser.sessionID, openedBy: .agent, activate: asked || broughtForward)
    tab.ensureWebView()
    noteAgentOpenedPage(in: browser.sessionID)
    willAct(on: tab)
    defer { didAct(on: tab) }
    await tab.waitUntilSettled(timeout: Self.loadTimeout)
    record(
      tool, in: browser, tab: tab, target: url.absoluteString, decision: .automatic,
      succeeded: tab.failure == nil)
    return status(of: tab, in: browser, broughtForward: broughtForward)
  }

  /// An address an agent typed: `localhost:5173` is taken for `http://localhost:5173`. Only what
  /// the web view shows is accepted.
  static func address(_ text: String?) throws -> URL {
    guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      throw BrowserToolFailure("Give an address with url.")
    }
    if text.hasPrefix("/") { text = "file://" + text }
    // `mailto:x` has a scheme; `localhost:5173` has a port.
    let hasScheme =
      text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:(?![0-9])"#, options: .regularExpression) != nil
    if !hasScheme { text = "http://" + text }
    guard let url = URL(string: text), url.scheme != nil else {
      throw BrowserToolFailure("\(text) is not an address.")
    }
    switch BrowserActionPolicy.decideNavigation(to: url) {
    case .allow: return url
    case .deny(let reason): throw BrowserToolFailure(reason)
    case .ask:
      throw BrowserToolFailure(
        "Only http, https and file addresses open in the web view; \(url.scheme ?? "") is not one.")
    }
  }

  // MARK: - Reporting

  private func listTabs(_ browser: SessionBrowser) -> BrowserToolResult {
    let active = browser.activeTab?.id
    let tabs: [JSONValue] = browser.allTabs.map { tab in
      // A page the agent may not read shows neither its title nor, unless the agent opened it,
      // more of its address than its site (#239): a title says what a private page is about.
      let readable = mayRead(tab.committedURL ?? tab.url, in: browser)
      let shownURL =
        readable || tab.openedBy == .agent ? tab.url.absoluteString : Self.siteAddress(tab.url)
      return [
        "id": .string(tab.id.description),
        "title": .string(readable ? tab.displayTitle : ""),
        "url": .string(shownURL),
        "readable": .bool(readable),
        "active": .bool(tab.id == active),
        "pinned": .bool(tab.isPinnedTicket),
        "loaded": .bool(tab.isLoaded),
        "loading": .bool(tab.isLoading),
        "openedBy": .string(tab.isPinnedTicket ? "ticket" : tab.openedBy.rawValue),
        "error": tab.failure.map { .string($0.agentDescription) } ?? .null,
      ]
    }
    return .text(JSONValue.array(tabs).jsonText)
  }

  private func status(
    of tab: BrowserTabModel, in browser: SessionBrowser, broughtForward: Bool = false
  ) -> BrowserToolResult {
    let readable = mayRead(tab.committedURL ?? tab.url, in: browser)
    var fields: [String: JSONValue] = [
      "id": .string(tab.id.description),
      "title": .string(readable ? tab.displayTitle : ""),
      "url": .string(tab.url.absoluteString),
      "loading": .bool(tab.isLoading),
    ]
    if !readable {
      fields["readable"] = false
      fields["note"] =
        "The title is withheld: page_read asks the user before anything of this site is read."
    }
    if broughtForward {
      fields["inFront"] = true
      fields["note"] = .string(
        "Opened in front: a page away from this Mac never loads in the background."
          + (readable ? "" : " The title is withheld: page_read asks the user first."))
    }
    if let failure = tab.failure {
      fields["error"] = .string(failure.agentDescription)
      fields["loaded"] = false
    } else if tab.hasCrashed {
      fields["error"] = "The page crashed; call tab_reload."
      fields["loaded"] = false
    } else {
      fields["loaded"] = .bool(!tab.isLoading)
    }
    return .text(JSONValue.object(fields).jsonText)
  }

  // MARK: - Reading

  /// A read the user's answer — or the policy — allowed: of which site, and how it was decided.
  struct AllowedRead {
    /// The document's address the decision was made on.
    let address: URL
    let origin: BrowserOrigin?
    let decision: BrowserActionRecord.Decision
  }

  /// Whether the agent may read what the tab holds (#239): free on this Mac, on a site always
  /// allowed, and on a site the user let the session read; asked anywhere else, once per site and
  /// session. Decided on the document the page holds, never on where a navigation is heading.
  func mayRead(
    _ tool: BrowserToolCatalog.Tool, _ tab: BrowserTabModel, webView: WKWebView,
    browser: SessionBrowser
  ) async throws -> AllowedRead {
    guard !tab.isLoading else {
      throw BrowserToolFailure(
        "The page is still loading: nothing was read. Wait a moment, then try again.")
    }
    // A load that failed leaves no document: its address is what its console speaks of.
    let committed = tab.committedURL ?? tab.url
    var reported: String?
    if BrowserOrigin(url: committed) == nil {
      reported =
        try await configuration.callAgent(
          "return location.origin;", arguments: [:], in: webView) as? String
    }
    let policyURL = Self.policyURL(committed: committed, reportedOrigin: reported)
    let site = BrowserOrigin(url: policyURL)
    switch BrowserActionPolicy.decide(
      .read, url: policyURL, grants: permissions.grants, sessionReads: browser.readableSites)
    {
    case .allow:
      guard let site, !site.isLocal else {
        return AllowedRead(address: committed, origin: site, decision: .automatic)
      }
      let always = permissions.grants.contains(site.grantKey)
      return AllowedRead(address: committed, origin: site, decision: always ? .always : .confirmed)
    case .deny(let reason):
      throw BrowserToolFailure(reason)
    case .ask:
      tab.isAgentActing = true
      let outcome = await ask(.read(tool: tool.name), tab: tab, in: browser.sessionID, grantKey: nil)
      tab.isAgentActing = false
      switch outcome {
      case .allowed:
        if let site { browser.allowReading(site.grantKey) }
      case .denied:
        record(tool, in: browser, tab: tab, target: "", decision: .denied, succeeded: false)
        throw BrowserToolFailure(
          "The user refused: nothing was read on \(site?.description ?? "the page").")
      case .expired:
        record(tool, in: browser, tab: tab, target: "", decision: .expired, succeeded: false)
        throw BrowserToolFailure(
          "Nobody answered within two minutes: nothing was read. Ask the user, then try again.")
      }
      let read = AllowedRead(address: committed, origin: site, decision: .confirmed)
      // What was allowed was this site: a page that moved while the question was on screen is
      // not read.
      try stillOn(read, tab)
      return read
    }
  }

  /// The page still holds the document the read was decided on — its site, at least: a local
  /// preview that went to a signed-in site meanwhile is not read without asking.
  func stillOn(_ read: AllowedRead, _ tab: BrowserTabModel) throws {
    let now = tab.committedURL ?? tab.url
    guard !tab.isLoading, BrowserOrigin(url: now) == BrowserOrigin(url: read.address) else {
      throw BrowserToolFailure(
        "The page changed before it could be read: nothing was read. Read it again.")
    }
  }

  /// Whether the agent may read an address without asking, as far as the policy knows it. A blank
  /// page is taken at its word here: this decides only what a list shows, never what is read.
  func mayRead(_ url: URL, in browser: SessionBrowser) -> Bool {
    BrowserActionPolicy.decide(
      .read, url: url, grants: permissions.grants, sessionReads: browser.readableSites) == .allow
  }

  /// An address away from this Mac: a site with its own cookies.
  static func isRemote(_ url: URL) -> Bool {
    guard let origin = BrowserOrigin(url: url) else { return false }
    return !origin.isLocal
  }

  /// An address cut to its site: `https://github.com/`.
  static func siteAddress(_ url: URL) -> String {
    guard let origin = BrowserOrigin(url: url), let script = scriptOrigin(origin) else {
      return url.scheme.map { "\($0):" } ?? ""
    }
    return script + "/"
  }

  private func record(
    _ tool: BrowserToolCatalog.Tool, in browser: SessionBrowser, tab: BrowserTabModel?,
    target: String, decision: BrowserActionRecord.Decision, succeeded: Bool = true
  ) {
    browser.record(
      BrowserActionRecord(
        date: Date(), tool: tool.name, origin: tab?.origin?.description ?? "",
        target: BrowserActionLog.shortened(target, to: 120), decision: decision,
        succeeded: succeeded),
      isRead: tool.actionClass == .read)
  }

  private static func trace(_ description: String, _ value: String?) -> String {
    guard let value else { return description }
    return "\(description) ← \(value)"
  }

  private static func elementTarget(_ arguments: JSONValue) -> [String: String] {
    var target: [String: String] = [:]
    if let ref = arguments["ref"]?.stringValue, !ref.isEmpty { target["ref"] = ref }
    if let selector = arguments["selector"]?.stringValue, !selector.isEmpty {
      target["selector"] = selector
    }
    return target
  }

  /// The page, loaded and settled, ready to be read or acted on.
  private func ready(_ tab: BrowserTabModel) async throws -> WKWebView {
    let webView = tab.ensureWebView()
    await tab.waitUntilSettled(timeout: Self.loadTimeout)
    if let failure = tab.failure { throw BrowserToolFailure(failure.agentDescription) }
    if tab.hasCrashed { throw BrowserToolFailure("The page crashed; call tab_reload.") }
    return webView
  }

  static func describe(_ error: any Error) -> String {
    if let failure = error as? BrowserToolFailure { return failure.message }
    let error = error as NSError
    // WebKit's own message for a script that threw carries what the script said.
    if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
      return message.replacingOccurrences(of: "Error: ", with: "")
    }
    return error.localizedDescription
  }

  // MARK: - Screenshot

  static func screenshot(of webView: WKWebView) async throws -> Data {
    let configuration = WKSnapshotConfiguration()
    let bounds = webView.bounds
    let longest = max(bounds.width, bounds.height)
    if longest > screenshotSide {
      configuration.snapshotWidth = NSNumber(value: Double(bounds.width * screenshotSide / longest))
    }
    let image = try await webView.takeSnapshot(configuration: configuration)
    guard let png = png(of: image, maximumSide: screenshotSide) else {
      throw BrowserToolFailure("The page could not be captured.")
    }
    return png
  }

  static func png(of image: NSImage, maximumSide: CGFloat) -> Data? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = min(1, maximumSide / max(size.width, size.height))
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}
