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
      willAct(on: tab)
      defer { didAct(on: tab) }
      tab.ensureWebView()
      tab.load(url)
      await tab.waitUntilSettled(timeout: Self.loadTimeout)
      record(
        tool, in: browser, tab: tab, target: url.absoluteString, decision: .automatic,
        succeeded: tab.failure == nil)
      return status(of: tab)
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
      return status(of: tab)
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
      let limit = min(
        max(arguments["maxChars"]?.intValue ?? Self.defaultReadLimit, 1_000), Self.maximumReadLimit)
      let mode = arguments["mode"]?.stringValue == "text" ? "text" : "snapshot"
      let text = try await configuration.callAgent(
        "return window.__vibeAgent.\(mode)(limit);", arguments: ["limit": limit], in: webView)
      record(tool, in: browser, tab: tab, target: mode, decision: .automatic)
      return .text((text as? String) ?? "")
    case "page_screenshot":
      let webView = try await ready(tab)
      let png = try await Self.screenshot(of: webView)
      record(tool, in: browser, tab: tab, target: "", decision: .automatic)
      return BrowserToolResult(content: [.image(png, mimeType: "image/png")])
    case "page_console":
      if !tab.isLoaded { _ = try await ready(tab) }
      let minimum =
        arguments["level"]?.stringValue.flatMap(BrowserConsoleEntry.Level.init) ?? .debug
      let limit = min(max(arguments["limit"]?.intValue ?? 200, 1), 200)
      let entries = tab.console.entries.filter { $0.level >= minimum }.suffix(limit)
      record(tool, in: browser, tab: tab, target: "\(entries.count) messages", decision: .automatic)
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
    let site = BrowserOrigin(url: committed)
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
    switch BrowserActionPolicy.decide(.act, url: committed, grants: permissions.grants) {
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
    guard !tab.isLoading, tab.committedURL.flatMap(BrowserOrigin.init(url:)) == site else {
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

  /// `location.origin` as a page reports it for an origin: no default port, IPv6 in brackets. `nil`
  /// for local files, whose origin a page reports as opaque.
  static func scriptOrigin(_ origin: BrowserOrigin) -> String? {
    guard origin.scheme == "http" || origin.scheme == "https" else { return nil }
    let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
    let defaultPort = origin.scheme == "http" ? 80 : 443
    guard let port = origin.port, port != defaultPort else { return "\(origin.scheme)://\(host)" }
    return "\(origin.scheme)://\(host):\(port)"
  }

  /// An expression is evaluated as it is; a body with `return` runs as an async function.
  static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
    if script.range(of: #"\breturn\b"#, options: .regularExpression) != nil {
      return try await webView.callAsyncJavaScript(
        script, arguments: [:], in: nil, contentWorld: .page)
    }
    return try await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
  }

  // MARK: - Opening

  private func openTab(
    _ arguments: JSONValue, browser: SessionBrowser, tool: BrowserToolCatalog.Tool
  ) async throws -> BrowserToolResult {
    let url = try Self.address(arguments["url"]?.stringValue)
    let activate = arguments["activate"]?.boolValue ?? true
    let tab = open(url, in: browser.sessionID, openedBy: .agent, activate: activate)
    tab.ensureWebView()
    noteAgentOpenedPage(in: browser.sessionID)
    willAct(on: tab)
    defer { didAct(on: tab) }
    await tab.waitUntilSettled(timeout: Self.loadTimeout)
    record(
      tool, in: browser, tab: tab, target: url.absoluteString, decision: .automatic,
      succeeded: tab.failure == nil)
    return status(of: tab)
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
      [
        "id": .string(tab.id.description),
        "title": .string(tab.displayTitle),
        "url": .string(tab.url.absoluteString),
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

  private func status(of tab: BrowserTabModel) -> BrowserToolResult {
    var fields: [String: JSONValue] = [
      "id": .string(tab.id.description),
      "title": .string(tab.displayTitle),
      "url": .string(tab.url.absoluteString),
      "loading": .bool(tab.isLoading),
    ]
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
