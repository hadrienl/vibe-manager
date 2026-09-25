import Foundation
import VibeDomain

/// Where each session's web view is kept between launches: its tabs, the one in front, whether it
/// was shown (#69). One document per session, beside the store, so that following a link never
/// rewrites the sessions.
public protocol BrowserStateStore: Sendable {
  /// What was kept, or an empty view when nothing was, or when it cannot be read.
  func load(_ id: SessionID) async -> SessionBrowserState
  func save(_ state: SessionBrowserState, for id: SessionID) async
  func remove(_ id: SessionID) async
}

/// What an agent did in a session's web view, kept with the session.
public protocol BrowserActionLogStore: Sendable {
  func load(_ id: SessionID) async -> [BrowserActionRecord]
  func save(_ records: [BrowserActionRecord], for id: SessionID) async
  func remove(_ id: SessionID) async
}

/// The sites where an agent may act without asking, as the user allowed them: a preference of this
/// Mac.
@MainActor
public protocol BrowserPermissionStore: AnyObject {
  var grants: Set<String> { get }
  func grant(_ key: String)
  func revoke(_ key: String)
}

/// Where a link clicked in a terminal goes.
public enum TerminalLinkDestination: String, Codable, CaseIterable, Sendable {
  case webView
  case defaultBrowser
}

/// The choices of Settings › Web View.
@MainActor
public protocol BrowserPreferences: AnyObject {
  /// Whether the agents are started with the tools that drive the web view.
  var givesAgentsWebView: Bool { get set }
  /// Whether the web view comes forward when an agent opens a page.
  var showsWebViewWhenAgentOpensPage: Bool { get set }
  var terminalLinks: TerminalLinkDestination { get set }
}

@MainActor
public final class InMemoryBrowserPreferences: BrowserPreferences {
  public var givesAgentsWebView: Bool
  public var showsWebViewWhenAgentOpensPage: Bool
  public var terminalLinks: TerminalLinkDestination

  public init(
    givesAgentsWebView: Bool = true,
    showsWebViewWhenAgentOpensPage: Bool = true,
    terminalLinks: TerminalLinkDestination = .webView
  ) {
    self.givesAgentsWebView = givesAgentsWebView
    self.showsWebViewWhenAgentOpensPage = showsWebViewWhenAgentOpensPage
    self.terminalLinks = terminalLinks
  }
}

@MainActor
public final class InMemoryBrowserPermissionStore: BrowserPermissionStore {
  public private(set) var grants: Set<String>

  public init(grants: Set<String> = []) {
    self.grants = grants
  }

  public func grant(_ key: String) {
    grants.insert(key)
  }

  public func revoke(_ key: String) {
    grants.remove(key)
  }
}

public actor InMemoryBrowserStateStore: BrowserStateStore {
  private var states: [SessionID: SessionBrowserState] = [:]

  public init() {}

  public func load(_ id: SessionID) -> SessionBrowserState {
    states[id] ?? SessionBrowserState()
  }

  public func save(_ state: SessionBrowserState, for id: SessionID) {
    states[id] = state
  }

  public func remove(_ id: SessionID) {
    states[id] = nil
  }
}

public actor InMemoryBrowserActionLogStore: BrowserActionLogStore {
  private var logs: [SessionID: [BrowserActionRecord]] = [:]

  public init() {}

  public func load(_ id: SessionID) -> [BrowserActionRecord] {
    logs[id] ?? []
  }

  public func save(_ records: [BrowserActionRecord], for id: SessionID) {
    logs[id] = records
  }

  public func remove(_ id: SessionID) {
    logs[id] = nil
  }
}

/// One thing an agent did, or tried to do, in a web view.
public struct BrowserActionRecord: Hashable, Codable, Sendable, Identifiable {
  public enum Decision: String, Codable, Sendable {
    /// Nothing needed asking: a read, a move, or an action on this Mac.
    case automatic
    /// Covered by an "Always Allow" for the site.
    case always
    case confirmed
    case denied
    case expired
  }

  public let id: UUID
  public let date: Date
  public let tool: String
  /// The site, as a person reads it.
  public let origin: String
  /// What was acted on — `button “Save”` — or what was read; already cut to size.
  public let target: String
  public let decision: Decision
  /// Whether the tool did what it was asked.
  public let succeeded: Bool
  /// How many times the same read was repeated in a row: reads are grouped so that the trace
  /// stays about what the agent did.
  public var count: Int

  public init(
    id: UUID = UUID(), date: Date, tool: String, origin: String, target: String,
    decision: Decision, succeeded: Bool, count: Int = 1
  ) {
    self.id = id
    self.date = date
    self.tool = tool
    self.origin = origin
    self.target = target
    self.decision = decision
    self.succeeded = succeeded
    self.count = count
  }
}

/// The trace of what agents did in a session's web view: bounded, and careful about what it keeps.
public struct BrowserActionLog: Sendable, Equatable {
  public static let capacity = 200
  /// A value typed into a page is kept this long at most.
  public static let valueLimit = 80
  public static let scriptLimit = 200

  public private(set) var records: [BrowserActionRecord]

  public init(records: [BrowserActionRecord] = []) {
    self.records = Array(records.suffix(Self.capacity))
  }

  /// Adds a record, newest last. A read repeating the one just before is counted there instead.
  public mutating func append(_ record: BrowserActionRecord, isRead: Bool) {
    if isRead, let last = records.last, last.tool == record.tool, last.origin == record.origin,
      last.decision == record.decision, last.succeeded == record.succeeded
    {
      var updated = record
      updated.count = last.count + 1
      records[records.count - 1] = BrowserActionRecord(
        id: last.id, date: record.date, tool: record.tool, origin: record.origin,
        target: record.target, decision: record.decision, succeeded: record.succeeded,
        count: updated.count)
      return
    }
    records.append(record)
    if records.count > Self.capacity {
      records.removeFirst(records.count - Self.capacity)
    }
  }

  public mutating func clear() {
    records = []
  }

  /// A value typed into a field, as the trace may keep it: never a password, a card or a one-time
  /// code, and never more than a line.
  public static func recordedValue(_ value: String, isSensitive: Bool) -> String {
    guard !isSensitive else { return "••••••" }
    return shortened(value, to: valueLimit)
  }

  public static func shortened(_ text: String, to limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit)) + "…"
  }
}
