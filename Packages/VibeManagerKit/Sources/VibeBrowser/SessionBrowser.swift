import Foundation
import Observation
import VibeApplication
import VibeDomain

/// One session's web view: its tabs, the ticket's pinned tab, the one in front, and what agents did
/// there (#69).
@MainActor
@Observable
public final class SessionBrowser {
  public let sessionID: SessionID
  /// The tabs after the ticket's, in the order shown.
  public private(set) var tabs: [BrowserTabModel] = []
  /// The ticket's tab, first and pinned, when the session has a ticket.
  public private(set) var ticketTab: BrowserTabModel?
  public private(set) var ticket: TicketResolution.Resolved?
  /// `nil` puts the ticket's tab in front.
  public private(set) var activeTabID: BrowserTabID?
  public private(set) var isVisible = false
  public private(set) var actionLog = BrowserActionLog()
  /// Agent actions recorded since the trace was last looked at: the badge on its button.
  public private(set) var unseenActionCount = 0
  /// An agent opened a page while the session was not on screen: its row says so.
  public internal(set) var hasUnseenAgentPage = false
  /// Whether what was kept has been read back yet.
  public internal(set) var isRestored = false

  @ObservationIgnored var stateDidChange: (@MainActor () -> Void)?
  @ObservationIgnored var logDidChange: (@MainActor () -> Void)?

  init(sessionID: SessionID) {
    self.sessionID = sessionID
  }

  /// Every tab, the ticket's first.
  public var allTabs: [BrowserTabModel] {
    (ticketTab.map { [$0] } ?? []) + tabs
  }

  public var activeTab: BrowserTabModel? {
    guard let activeTabID else { return ticketTab ?? tabs.first }
    return tabs.first { $0.id == activeTabID } ?? ticketTab ?? tabs.first
  }

  public func tab(_ id: BrowserTabID) -> BrowserTabModel? {
    allTabs.first { $0.id == id }
  }

  /// A tab named by an agent: its short id, or its whole identifier.
  func tab(named name: String) -> BrowserTabModel? {
    let name = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard !name.isEmpty else { return nil }
    return allTabs.first {
      $0.id.description == name || $0.id.rawValue.uuidString.lowercased() == name
    }
  }

  var persisted: SessionBrowserState {
    SessionBrowserState(
      tabs: tabs.map(\.persisted),
      activeTabID: activeTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil },
      isVisible: isVisible)
  }

  // MARK: - Changes

  func restore(
    _ state: SessionBrowserState, records: [BrowserActionRecord],
    make: (BrowserTab) -> BrowserTabModel
  ) {
    // Whatever was opened before the file was read stays, after what was kept.
    let opened = tabs
    tabs = state.tabs.map(make) + opened
    if activeTabID == nil { activeTabID = state.activeTabID }
    if !isVisible { isVisible = state.isVisible }
    actionLog = BrowserActionLog(records: records + actionLog.records)
    isRestored = true
  }

  func append(_ tab: BrowserTabModel, activate: Bool, after anchor: BrowserTabID? = nil) {
    if let anchor, let index = tabs.firstIndex(where: { $0.id == anchor }) {
      tabs.insert(tab, at: index + 1)
    } else {
      tabs.append(tab)
    }
    if activate { activeTabID = tab.id }
    stateDidChange?()
  }

  func remove(_ id: BrowserTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let removed = tabs.remove(at: index)
    removed.discard()
    if activeTabID == id {
      // The neighbour on the right, as browsers do, else the one on the left, else the ticket.
      activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
    }
    stateDidChange?()
  }

  public func activate(_ id: BrowserTabID) {
    guard tab(id) != nil else { return }
    activeTabID = ticketTab?.id == id ? nil : id
    stateDidChange?()
  }

  /// Moves a tab to another place among the unpinned tabs.
  public func move(_ id: BrowserTabID, to destination: Int) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = tabs.remove(at: index)
    tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    stateDidChange?()
  }

  /// The tab after, or before, the one in front, around the ends.
  public func activateNeighbour(offset: Int) {
    let all = allTabs
    guard !all.isEmpty else { return }
    let current = activeTab.flatMap { tab in all.firstIndex { $0.id == tab.id } } ?? 0
    let next = (current + offset % all.count + all.count) % all.count
    activate(all[next].id)
  }

  func setVisible(_ isVisible: Bool) {
    guard self.isVisible != isVisible else { return }
    self.isVisible = isVisible
    stateDidChange?()
  }

  func setTicket(_ ticket: TicketResolution.Resolved?, make: (URL) -> BrowserTabModel) {
    guard ticket != self.ticket else { return }
    let wasInFront = activeTabID == nil
    self.ticket = ticket
    guard let ticket else {
      ticketTab?.discard()
      ticketTab = nil
      return
    }
    if let ticketTab {
      if ticketTab.url != ticket.url { ticketTab.load(ticket.url) }
    } else {
      ticketTab = make(ticket.url)
      // A session that had its own tab in front keeps it there.
      if !wasInFront { return }
    }
  }

  func record(_ record: BrowserActionRecord, isRead: Bool) {
    actionLog.append(record, isRead: isRead)
    unseenActionCount += 1
    logDidChange?()
  }

  public func markTraceSeen() {
    unseenActionCount = 0
  }

  func clearTrace() {
    actionLog.clear()
    unseenActionCount = 0
    logDidChange?()
  }

  func discardAll() {
    for tab in allTabs { tab.discard() }
  }
}
