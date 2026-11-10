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
  /// The tabs after the ticket's, in the order shown: the pinned ones first (#536).
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
  /// The sites away from this Mac the user let this session's agent read (#239), by
  /// `BrowserOrigin.grantKey`. Kept for this run only: a relaunch asks again. Shown in the trace,
  /// where the user takes one back (#288).
  public private(set) var readableSites: Set<String> = []
  /// The sites the user refused to let this session's agent read: not asked again this session,
  /// so that an agent cannot ask until the user gives in — unless the user takes it back (#288).
  public private(set) var refusedSites: Set<String> = []

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

  /// How many tabs the user pinned: the first ones of `tabs`.
  public var pinnedCount: Int {
    tabs.prefix { $0.isPinned }.count
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
    let restored = state.tabs.map(make) + opened
    // Pinned first, whatever the file said: a tab is never kept between pinned ones unpinned.
    tabs = restored.filter(\.isPinned) + restored.filter { !$0.isPinned }
    if activeTabID == nil { activeTabID = state.activeTabID }
    if !isVisible { isVisible = state.isVisible }
    actionLog = BrowserActionLog(records: records + actionLog.records)
    isRestored = true
  }

  /// A new tab after `anchor`, and after the tabs `anchor` opened before it since the user last
  /// turned to a tab: three links ⌘-clicked in a page line up in the order they were clicked (#186).
  /// `isOpener`: the tab was opened from `anchor`'s page, rather than only placed after it — a
  /// terminal's link, an agent's page — and later ones from that page line up after it.
  func append(
    _ tab: BrowserTabModel, activate: Bool, after anchor: BrowserTabID? = nil,
    isOpener: Bool = false
  ) {
    if let anchor, let index = tabs.firstIndex(where: { $0.id == anchor }) {
      // Opened from a pinned tab, it goes first among the others: it is not pinned itself.
      var position = max(index + 1, pinnedCount)
      while position < tabs.count, tabs[position].openerID == anchor { position += 1 }
      if isOpener { tab.openerID = anchor }
      tabs.insert(tab, at: position)
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
    // Turning to a tab ends the run of tabs opened from the one before: the next ones line up
    // after their opener again.
    for tab in tabs { tab.openerID = nil }
    activeTabID = ticketTab?.id == id ? nil : id
    stateDidChange?()
  }

  /// Pins a tab, last of the pinned ones, or unpins it, first of the others (#536).
  public func setPinned(_ id: BrowserTabID, _ isPinned: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != isPinned
    else { return }
    let tab = tabs.remove(at: index)
    tab.isPinned = isPinned
    tabs.insert(tab, at: pinnedCount)
    stateDidChange?()
  }

  /// Moves a tab where it was dropped: before or after `target`, pinned when `target` is (#536).
  /// Dropped on the ticket's, it becomes the first pinned tab.
  public func move(_ id: BrowserTabID, nextTo target: BrowserTabID, after: Bool) {
    guard id != target, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    if target == ticketTab?.id {
      let tab = tabs.remove(at: index)
      tab.isPinned = true
      tabs.insert(tab, at: 0)
      stateDidChange?()
      return
    }
    guard let anchor = tabs.first(where: { $0.id == target }) else { return }
    let tab = tabs.remove(at: index)
    tab.isPinned = anchor.isPinned
    let position = tabs.firstIndex { $0.id == target } ?? tabs.count
    tabs.insert(tab, at: after ? position + 1 : position)
    stateDidChange?()
  }

  /// Moves a tab one place up (`-1`) or down (`1`) among the pinned tabs, or among the others: the
  /// keyboard's and VoiceOver's way to do what dragging it does (#230). Pinning it is what takes it
  /// from one group to the other.
  public func moveTab(_ id: BrowserTabID, by offset: Int) {
    guard let index = tabs.firstIndex(where: { $0.id == id }),
      let destination = Self.place(of: index, movedBy: offset, within: group(of: index))
    else { return }
    let tab = tabs.remove(at: index)
    tabs.insert(tab, at: destination)
    stateDidChange?()
  }

  /// Whether `moveTab(_:by:)` has somewhere to go.
  public func canMoveTab(_ id: BrowserTabID, by offset: Int) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    return Self.place(of: index, movedBy: offset, within: group(of: index)) != nil
  }

  /// The places of the tabs pinned like the one at `index`.
  private func group(of index: Int) -> Range<Int> {
    tabs[index].isPinned ? 0..<pinnedCount : pinnedCount..<tabs.count
  }

  /// Where a tab at `index` goes when moved by `offset`, or `nil` past either end of its group.
  static func place(of index: Int, movedBy offset: Int, within group: Range<Int>) -> Int? {
    let destination = index + offset
    return destination != index && group.contains(destination) ? destination : nil
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

  func allowReading(_ site: String) {
    readableSites.insert(site)
    refusedSites.remove(site)
  }

  /// The latest answer wins: a site is never both readable and refused.
  func refuseReading(_ site: String) {
    readableSites.remove(site)
    refusedSites.insert(site)
  }

  /// The user took back what they answered for a site: the next read asks again (#288).
  func forgetReading(_ site: String) {
    readableSites.remove(site)
    refusedSites.remove(site)
  }

  func forgetReadableSites() {
    readableSites = []
    refusedSites = []
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
