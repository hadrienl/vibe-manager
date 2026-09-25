import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain
import WebKit

/// What the user answered to an agent asking to act as them.
public enum BrowserPermissionAnswer: Sendable {
  case allowOnce
  case alwaysAllow
  case deny
}

/// An agent waiting for the user: to act on a page away from this Mac, to download a file, or to
/// open another application (#69).
public struct BrowserPermissionRequest: Identifiable, Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// `page_click`, `page_fill`, `page_evaluate`. `value` is what would be typed, masked in a
    /// sensitive field.
    case act(tool: String, target: String, value: String?)
    case effect(BrowserAgentEffect)
  }

  public let id: UUID
  public let sessionID: SessionID
  public let tabID: BrowserTabID
  public let kind: Kind
  /// The site, as a person reads it.
  public let site: String
  /// The key an "Always Allow" is kept under; `nil` where it cannot be offered.
  public let grantKey: String?
  public let expiresAt: Date
}

/// Every session's web view, and what the agents do in them (#69).
@MainActor
@Observable
public final class BrowserWorkspace {
  public static let permissionTimeout: Duration = .seconds(120)
  static let loadTimeout: Duration = .seconds(15)
  /// A tab nobody has looked at or used for this long, in a session not on screen, lets its page
  /// go: it loads again when it is next wanted.
  static let idleDiscardInterval: TimeInterval = 30 * 60

  public let configuration: BrowserWebConfiguration
  public let preferences: any BrowserPreferences
  public let permissions: any BrowserPermissionStore
  public private(set) var pendingRequests: [BrowserPermissionRequest] = []
  /// What the always-allowed sites are, as the settings list them.
  public private(set) var grants: Set<String>

  /// The session on screen, if any: an agent's page brings the web view forward only there.
  @ObservationIgnored public var selectedSessionID: (@MainActor () -> SessionID?)?
  /// Told when a session's web view should be shown because an agent opened a page in it.
  @ObservationIgnored public var agentDidOpenPage: (@MainActor (SessionID) -> Void)?
  /// Told when a session's web view is shown or hidden, so the layout can follow.
  @ObservationIgnored public var visibilityDidChange: (@MainActor (SessionID) -> Void)?

  @ObservationIgnored private var browsers: [SessionID: SessionBrowser] = [:]
  @ObservationIgnored private var restoreTasks: [SessionID: Task<Void, Never>] = [:]
  @ObservationIgnored private var saveTasks: [SessionID: Task<Void, Never>] = [:]
  @ObservationIgnored private var logSaveTasks: [SessionID: Task<Void, Never>] = [:]
  @ObservationIgnored private var answers: [UUID: CheckedContinuation<AnswerOutcome, Never>] = [:]
  @ObservationIgnored private var lastUse: [BrowserTabID: Date] = [:]
  @ObservationIgnored private let stateStore: any BrowserStateStore
  @ObservationIgnored private let logStore: any BrowserActionLogStore
  @ObservationIgnored private let saveDelay: Duration

  public init(
    stateStore: any BrowserStateStore = InMemoryBrowserStateStore(),
    logStore: any BrowserActionLogStore = InMemoryBrowserActionLogStore(),
    permissions: any BrowserPermissionStore = InMemoryBrowserPermissionStore(),
    preferences: any BrowserPreferences = InMemoryBrowserPreferences(),
    configuration: BrowserWebConfiguration = BrowserWebConfiguration(storeIdentifierFile: nil),
    saveDelay: Duration = .milliseconds(500)
  ) {
    self.stateStore = stateStore
    self.logStore = logStore
    self.permissions = permissions
    self.preferences = preferences
    self.configuration = configuration
    self.saveDelay = saveDelay
    grants = permissions.grants
  }

  // MARK: - Sessions

  /// The session's web view, read back from its document the first time it is asked for.
  public func browser(for id: SessionID) -> SessionBrowser {
    if let browser = browsers[id] { return browser }
    let browser = SessionBrowser(sessionID: id)
    browser.stateDidChange = { [weak self] in self?.scheduleSave(id) }
    browser.logDidChange = { [weak self] in self?.scheduleLogSave(id) }
    browsers[id] = browser
    restoreTasks[id] = Task { [weak self, stateStore, logStore] in
      let state = await stateStore.load(id)
      let records: [BrowserActionRecord] = await logStore.load(id)
      guard let self else { return }
      browser.restore(state, records: records) { tab in
        self.makeTab(tab.url, id: tab.id, title: tab.title, openedBy: tab.openedBy, in: id)
      }
      self.restoreTasks[id] = nil
      self.visibilityDidChange?(id)
    }
    return browser
  }

  /// The session's web view, once what was kept has been read.
  public func restoredBrowser(for id: SessionID) async -> SessionBrowser {
    let browser = browser(for: id)
    await restoreTasks[id]?.value
    return browser
  }

  public func isVisible(_ id: SessionID) -> Bool {
    browsers[id]?.isVisible ?? false
  }

  public func setVisible(_ isVisible: Bool, for id: SessionID) {
    let browser = browser(for: id)
    browser.setVisible(isVisible)
    visibilityDidChange?(id)
  }

  /// The session is on screen: whatever its agent opened meanwhile has been seen.
  public func sessionDidAppear(_ id: SessionID) {
    browsers[id]?.hasUnseenAgentPage = false
    discardIdlePages(except: id)
  }

  /// The ticket of a session, as its store and its branch say it now.
  public func updateTicket(
    stored: SessionTicket?, branch: String?, repository: RepositoryWebAddress?, for id: SessionID
  ) {
    let resolved = TicketResolution.resolve(stored: stored, branch: branch, repository: repository)
    browser(for: id).setTicket(resolved) { url in
      self.makeTab(url, openedBy: .user, isPinnedTicket: true, in: id)
    }
  }

  /// The session is archived: its pages are let go, what it was is kept.
  public func release(_ id: SessionID) {
    browsers[id]?.discardAll()
    cancelRequests(of: id)
  }

  /// The session is deleted: its web view goes with it.
  public func forget(_ id: SessionID) async {
    release(id)
    browsers[id] = nil
    saveTasks[id]?.cancel()
    logSaveTasks[id]?.cancel()
    await stateStore.remove(id)
    await logStore.remove(id)
  }

  /// Writes whatever is pending, when the application quits.
  public func flush() async {
    for (id, browser) in browsers where browser.isRestored {
      saveTasks[id]?.cancel()
      logSaveTasks[id]?.cancel()
      await stateStore.save(browser.persisted, for: id)
      await logStore.save(browser.actionLog.records, for: id)
    }
    saveTasks = [:]
    logSaveTasks = [:]
  }

  // MARK: - Tabs

  /// Opens an address in a new tab of a session, after the tab in front.
  @discardableResult
  public func open(
    _ url: URL, in id: SessionID, openedBy: BrowserTab.Opener, activate: Bool = true
  ) -> BrowserTabModel {
    let browser = browser(for: id)
    let tab = makeTab(url, openedBy: openedBy, in: id)
    browser.append(
      tab, activate: activate,
      after: browser.activeTab.flatMap {
        $0.isPinnedTicket ? nil : $0.id
      })
    if activate || openedBy != .agent { tab.ensureWebView() }
    touch(tab)
    if !browser.isVisible {
      if openedBy != .agent || preferences.showsWebViewWhenAgentOpensPage {
        setVisible(true, for: id)
      }
    }
    return tab
  }

  /// A window a page opened, shown as a tab after its opener's, in front.
  private func adoptPopup(_ popup: WKWebView, url: URL, byAgent: Bool, in id: SessionID) {
    let browser = browser(for: id)
    let tab = makeTab(url, openedBy: byAgent ? .agent : .user, in: id)
    tab.adopt(popup)
    browser.append(
      tab, activate: true,
      after: browser.activeTab.flatMap {
        $0.isPinnedTicket ? nil : $0.id
      })
    touch(tab)
  }

  /// A link from a terminal: the tab that already shows it comes forward, else a new one opens.
  public func openLink(_ url: URL, in id: SessionID) {
    let browser = browser(for: id)
    if let existing = browser.allTabs.first(where: { $0.url == url }) {
      browser.activate(existing.id)
      existing.ensureWebView()
      setVisible(true, for: id)
      return
    }
    open(url, in: id, openedBy: .terminalLink)
  }

  public func close(_ tabID: BrowserTabID, in id: SessionID) {
    guard let browser = browsers[id], let tab = browser.tab(tabID), !tab.isPinnedTicket else {
      return
    }
    browser.remove(tabID)
    lastUse[tabID] = nil
  }

  /// The tab is on screen: it is loaded if it was not, and taken out of the parking window.
  public func show(_ tab: BrowserTabModel) -> WKWebView {
    let webView = tab.ensureWebView()
    configuration.unpark(webView)
    touch(tab)
    return webView
  }

  /// The tab left the screen: its page waits in the parking window.
  public func hide(_ webView: WKWebView) {
    webView.removeFromSuperview()
    configuration.park(webView)
  }

  public func clearTrace(of id: SessionID) {
    browsers[id]?.clearTrace()
  }

  public func revokeGrant(_ key: String) {
    permissions.revoke(key)
    grants = permissions.grants
  }

  private func makeTab(
    _ url: URL, id tabID: BrowserTabID = BrowserTabID(), title: String = "",
    openedBy: BrowserTab.Opener, isPinnedTicket: Bool = false, in id: SessionID
  ) -> BrowserTabModel {
    let tab = BrowserTabModel(
      id: tabID, url: url, title: title, openedBy: openedBy, isPinnedTicket: isPinnedTicket,
      configuration: configuration)
    tab.didChange = { [weak self] in
      guard !isPinnedTicket else { return }
      self?.scheduleSave(id)
    }
    tab.openInNewTab = { [weak self] url, byAgent in
      self?.open(url, in: id, openedBy: byAgent ? .agent : .user)
    }
    tab.openPopup = { [weak self] popup, url, byAgent in
      self?.adoptPopup(popup, url: url, byAgent: byAgent, in: id)
    }
    tab.didCloseWindow = { [weak self, weak tab] in
      guard let self, let tab, !tab.isPinnedTicket else { return }
      self.close(tab.id, in: id)
    }
    tab.confirmAgentEffect = { [weak self] effect, tab in
      guard let self else { return false }
      let outcome = await self.ask(
        .effect(effect), tab: tab, in: id, grantKey: nil)
      return outcome.isAllowed
    }
    return tab
  }

  private func touch(_ tab: BrowserTabModel) {
    lastUse[tab.id] = Date()
  }

  private func discardIdlePages(except visible: SessionID) {
    let limit = Date().addingTimeInterval(-Self.idleDiscardInterval)
    for (id, browser) in browsers where id != visible {
      for tab in browser.allTabs where tab.isLoaded && !tab.isAgentActing {
        if (lastUse[tab.id] ?? .distantPast) < limit { tab.discard() }
      }
    }
  }

  private func scheduleSave(_ id: SessionID) {
    guard let browser = browsers[id], browser.isRestored else { return }
    saveTasks[id]?.cancel()
    saveTasks[id] = Task { [weak self, stateStore, saveDelay] in
      try? await Task.sleep(for: saveDelay)
      guard !Task.isCancelled else { return }
      await stateStore.save(browser.persisted, for: id)
      self?.saveTasks[id] = nil
    }
  }

  private func scheduleLogSave(_ id: SessionID) {
    guard let browser = browsers[id], browser.isRestored else { return }
    logSaveTasks[id]?.cancel()
    logSaveTasks[id] = Task { [weak self, logStore, saveDelay] in
      try? await Task.sleep(for: saveDelay)
      guard !Task.isCancelled else { return }
      await logStore.save(browser.actionLog.records, for: id)
      self?.logSaveTasks[id] = nil
    }
  }

  // MARK: - Asking the user

  enum AnswerOutcome {
    case allowed(always: Bool)
    case denied
    case expired

    var isAllowed: Bool {
      if case .allowed = self { return true }
      return false
    }
  }

  public func requests(for id: SessionID) -> [BrowserPermissionRequest] {
    pendingRequests.filter { $0.sessionID == id }
  }

  public func answer(_ request: BrowserPermissionRequest, with answer: BrowserPermissionAnswer) {
    switch answer {
    case .allowOnce:
      resolve(request.id, with: .allowed(always: false))
    case .alwaysAllow:
      if let key = request.grantKey {
        permissions.grant(key)
        grants = permissions.grants
      }
      resolve(request.id, with: .allowed(always: true))
    case .deny:
      resolve(request.id, with: .denied)
    }
  }

  func ask(
    _ kind: BrowserPermissionRequest.Kind, tab: BrowserTabModel, in id: SessionID,
    grantKey: String?
  ) async -> AnswerOutcome {
    let request = BrowserPermissionRequest(
      id: UUID(), sessionID: id, tabID: tab.id, kind: kind,
      site: tab.origin?.description ?? tab.url.absoluteString, grantKey: grantKey,
      expiresAt: Date().addingTimeInterval(
        TimeInterval(Self.permissionTimeout.components.seconds)))
    pendingRequests.append(request)
    // The session's web view comes forward with the question in it.
    if !(browsers[id]?.isVisible ?? false) { setVisible(true, for: id) }
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: Self.permissionTimeout)
      guard !Task.isCancelled else { return }
      self?.resolve(request.id, with: .expired)
    }
    let outcome = await withCheckedContinuation { continuation in
      answers[request.id] = continuation
    }
    timeout.cancel()
    return outcome
  }

  private func resolve(_ requestID: UUID, with outcome: AnswerOutcome) {
    pendingRequests.removeAll { $0.id == requestID }
    answers.removeValue(forKey: requestID)?.resume(returning: outcome)
  }

  private func cancelRequests(of id: SessionID) {
    for request in pendingRequests where request.sessionID == id {
      resolve(request.id, with: .denied)
    }
  }

  // MARK: - Tools

  /// The tab a tool names, in this session only: an identifier from another session is as unknown
  /// here as one that never existed.
  func target(_ arguments: JSONValue, in browser: SessionBrowser) throws
    -> BrowserTabModel
  {
    if let name = arguments["tab"]?.stringValue, !name.isEmpty {
      guard let tab = browser.tab(named: name) else {
        throw BrowserToolFailure("No tab \(name) in this session's web view: call tabs_list.")
      }
      return tab
    }
    guard let tab = browser.activeTab else {
      throw BrowserToolFailure(
        "This session's web view has no tab. Open one with tab_open.")
    }
    return tab
  }

  func willAct(on tab: BrowserTabModel) {
    tab.isAgentActing = true
    tab.agentDrivenUntil = Date().addingTimeInterval(3)
    touch(tab)
  }

  func didAct(on tab: BrowserTabModel) {
    tab.isAgentActing = false
    tab.agentDrivenUntil = Date().addingTimeInterval(2)
  }

  func noteAgentOpenedPage(in id: SessionID) {
    if selectedSessionID?() != id {
      browsers[id]?.hasUnseenAgentPage = true
    }
    agentDidOpenPage?(id)
  }
}

/// A tool that could not do what it was asked, and why, as the agent reads it.
public struct BrowserToolFailure: Error, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }
}
