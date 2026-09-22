import Foundation
import Observation
import VibeApplication
import VibeDomain
import VibeTerminalUI

@MainActor
@Observable
public final class AppModel {
  public enum State: Equatable {
    case idle
    case loading
    case loaded([WorkSession])
    case failed(message: String, canRestoreBackup: Bool)
  }

  /// A failure that struck while something was already on screen.
  ///
  /// Kept apart from `State.failed`: that state is the whole screen, which is right for a first
  /// load that found nothing, and wrong for a refresh over a workspace the user is working in.
  public struct RefreshFailure: Equatable {
    public let message: String
    public let canRestoreBackup: Bool
  }

  public private(set) var state: State = .idle
  public private(set) var refreshFailure: RefreshFailure?
  public private(set) var agentDiagnostics: [AgentDiagnostic] = []
  public private(set) var isRefreshingAgents = false
  public private(set) var selectedSessionID: SessionID?
  public private(set) var isPresentingNewSession = false
  public private(set) var newSessionModel: NewSessionModel?
  /// What each session's agent can do right now, refreshed with the detections. Held here so
  /// that the sidebar and the inspector read the same answer instead of each probing again.
  public private(set) var resolutions: [SessionID: SessionAgentResolution] = [:]

  /// The session the user asked to archive, held until they confirm. Archiving is reversible,
  /// but it moves a session out of sight, and a slip of the pointer must not do that.
  public private(set) var pendingArchive: WorkSession?
  /// A process the system would not let go of. Reported rather than swallowed: the promise that
  /// nothing stays attached to an archived session is only worth making if its failure is said.
  public private(set) var detachWarning: DetachWarning?

  /// A stop that could not be confirmed.
  public struct DetachWarning: Equatable {
    /// What the user actually asked for. Closing and archiving both stop a process, and a
    /// warning that named the wrong one would report an archive that never happened.
    public enum Action: Equatable {
      case closed
      case archived

      var verb: String {
        switch self {
        case .closed: return "closed"
        case .archived: return "archived"
        }
      }
    }

    public let action: Action
    public let sessionName: String
    public let processIdentifier: Int32

    public var message: String {
      """
      \(sessionName) was \(action.verb), but its process (pid \(processIdentifier)) did not \
      answer the stop and may still be running.
      """
    }

    public var suggestion: String {
      "Check Activity Monitor for a leftover process."
    }
  }

  /// Restarts under way, from the moment the command is pressed to the moment a process exists
  /// or the attempt has failed.
  ///
  /// This is the lock that matters. The launcher already refuses to start a session whose pane
  /// is running, and the domain refuses to reopen anything but a closed session — but between
  /// the command and the first process there is a window where neither has anything to say, and
  /// it is exactly as long as a detection plus a plan.
  public private(set) var restartingSessionIDs: Set<SessionID> = []
  /// A restart waiting on the user, because it is about to start a second conversation.
  public private(set) var pendingRestart: PendingRestart?
  /// A restart that never reached a process.
  public private(set) var restartFailure: RestartFailure?
  /// A resumed conversation the agent gave up on within seconds of being handed it.
  public private(set) var resumeFailure: ResumeFailure?

  /// When each resumed conversation was handed to its agent, kept only for as long as it takes
  /// to tell a refused resume from an ordinary exit.
  private var resumeAttempts: [SessionID: Date] = [:]

  /// How long after a resume an exit still counts as the resume being refused.
  ///
  /// Long enough for a CLI to start, fail to find the conversation and say so; short enough that
  /// an agent someone worked in for a minute and quit is never mistaken for one.
  static let resumeProbation: TimeInterval = 8

  /// A restart the user has to confirm, and the summary it would send.
  public struct PendingRestart: Equatable {
    public let sessionID: SessionID
    public let sessionName: String
    /// Why the agent's own conversation is not being resumed.
    public let explanation: String
    /// The generated summary, which the user may edit before it is sent.
    public let briefText: String
    public let isTruncated: Bool
    /// `false` when this agent takes no initial prompt at all: there is then nothing to edit,
    /// and saying so is more honest than showing an empty box.
    public let carriesContext: Bool
  }

  public struct RestartFailure: Equatable {
    public let sessionName: String
    public let message: String
    public let suggestion: String?
  }

  public struct ResumeFailure: Equatable {
    public let sessionID: SessionID
    public let sessionName: String

    public var message: String {
      "\(sessionName) stopped as soon as its conversation was resumed; the agent may no longer have it."
    }
  }

  /// The selection restored from the layout, kept until a load can tell whether it still exists.
  private var preferredSelection: SessionID?
  private var resolutionTask: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?

  public let layout: WorkspaceLayoutController
  /// Absent in a workspace assembled without the system around it — tests and previews. The
  /// application always has one.
  public let permissions: PermissionsModel?

  private let repository: any SessionRepository
  private let loadSessions: LoadSessions
  private let recovery: (any SessionStoreRecovery)?
  private let agents: (any AgentProviderResolving)?
  private let launcher: SessionLauncher?
  private let defaultWorkingDirectoryPath: String?
  private let closeSession: CloseSession
  private let archiveSession: ArchiveSession
  private let restoreSession: RestoreSession
  private let restartSession: RestartSession?
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    recovery: (any SessionStoreRecovery)? = nil,
    agents: (any AgentProviderResolving)? = nil,
    launcher: SessionLauncher? = nil,
    defaultWorkingDirectoryPath: String? = nil,
    layout: WorkspaceLayoutController = WorkspaceLayoutController(),
    permissions: PermissionsModel? = nil,
    // Only the resume probation reads it, and it is the one rule here measured in seconds of real
    // time: without a clock to move, its far side could only be tested by waiting eight seconds.
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.clock = clock
    self.permissions = permissions
    self.repository = repository
    loadSessions = LoadSessions(repository: repository)
    self.recovery = recovery
    self.agents = agents
    self.launcher = launcher
    self.defaultWorkingDirectoryPath = defaultWorkingDirectoryPath
    self.layout = layout

    // A workspace without a launcher has nothing running, so the use cases are handed a runtime
    // that says exactly that rather than an optional they would each have to second-guess.
    let runtime: any SessionRuntime = launcher ?? DetachedSessionRuntime()
    closeSession = CloseSession(repository: repository, runtime: runtime)
    archiveSession = ArchiveSession(repository: repository, runtime: runtime)
    restoreSession = RestoreSession(repository: repository)
    // A workspace without agents cannot build a launch plan, so it cannot restart anything —
    // and saying that with an optional is clearer than a use case that would refuse every call.
    restartSession = agents.map { RestartSession(repository: repository, agents: $0) }

    launcher?.sessionDidClose = { [weak self] id in
      guard let self else { return }
      self.noteProcessDidFinish(id)
      // The store already says the session is closed; the list on screen is what has to catch up.
      Task { await self.reload() }
    }
  }

  public var sessions: [WorkSession] {
    guard case .loaded(let sessions) = state else { return [] }
    return sessions
  }

  public var selectedSession: WorkSession? {
    sessions.first { $0.id == selectedSessionID }
  }

  // MARK: - History and filtering

  /// What the user is typing in the search field. Held here rather than in the stored layout:
  /// every keystroke would otherwise restart that save's delay and starve the write waiting it
  /// out, so a scope change followed by a burst of typing and a quit would never be persisted.
  public private(set) var searchText: String = ""

  public var filter: SessionFilter {
    var filter = layout.filter
    filter.searchText = searchText
    return filter
  }

  /// What the sidebar lists. Every session is still held — and every terminal still mounted —
  /// so narrowing the list never stops an agent or throws away what one has already said.
  public var visibleSessions: [WorkSession] {
    filter.apply(to: sessions)
  }

  public var archivedSessionCount: Int {
    sessions.filter { $0.status == .archived }.count
  }

  public var availableProviderIDs: [String] {
    SessionFilter.availableProviderIDs(in: sessions)
  }

  public var availableRepositoryPaths: [String] {
    SessionFilter.availableRepositoryPaths(in: sessions)
  }

  public func update(filter change: (inout SessionFilter) -> Void) {
    var updated = filter
    change(&updated)
    guard updated != filter else { return }
    searchText = updated.searchText
    updated.searchText = ""
    guard updated != layout.filter else { return }
    layout.setFilter(updated)
  }

  /// Changing scope moves the user somewhere else, so the selection follows.
  public func setScope(_ scope: SessionScope) {
    update { $0.scope = scope }
    reconcileSelection()
  }

  public func cycleScope() {
    let scopes = SessionScope.allCases
    guard let index = scopes.firstIndex(of: filter.scope) else { return }
    setScope(scopes[(index + 1) % scopes.count])
  }

  public func setSort(_ sort: SessionSort) {
    update { $0.sort = sort }
  }

  public func setSearchText(_ text: String) {
    update { $0.searchText = text }
  }

  public func toggleProviderFacet(_ providerID: String) {
    update {
      if $0.agentProviderIDs.contains(providerID) {
        $0.agentProviderIDs.remove(providerID)
      } else {
        $0.agentProviderIDs.insert(providerID)
      }
    }
  }

  public func setRepositoryFacet(_ path: String?) {
    update { $0.repositoryPath = path }
  }

  public func clearNarrowing() {
    update {
      $0.searchText = ""
      $0.agentProviderIDs = []
      $0.repositoryPath = nil
    }
  }

  /// Keeps the selection on something the user can actually see.
  ///
  /// Called when their place genuinely moved — a scope change, an archive, a reload — and never
  /// while they type. Search narrows the list as the query grows, and handing the detail column
  /// to another session on every keystroke would swap the terminal they are reading out from
  /// under them, then leave it swapped once the query is cleared.
  ///
  /// With nothing visible the selection is left alone rather than cleared: a load caught
  /// mid-write comes back short, and persisting a fallback there would lose their place for good.
  private func reconcileSelection() {
    let visible = visibleSessions
    guard let first = visible.first else { return }
    if let selectedSessionID, visible.contains(where: { $0.id == selectedSessionID }) { return }
    apply(selection: first.id)
  }

  // MARK: - Lifecycle commands

  public func canClose(_ session: WorkSession) -> Bool {
    session.status == .active || launcher?.isRunning(session.id) == true
  }

  public func canArchive(_ session: WorkSession) -> Bool {
    session.status != .archived
  }

  public func canRestore(_ session: WorkSession) -> Bool {
    session.status == .archived
  }

  /// Stops the agent and keeps everything else. The pane stays mounted so the last thing the
  /// agent said is still on screen.
  public func close(_ id: SessionID) async {
    do {
      let closure = try await closeSession(id: id)
      report(closure.detachment, for: closure.session, action: .closed)
    } catch {
      await report(error)
    }
    await reload()
  }

  /// Opens the confirmation rather than archiving. The command is reversible, but it takes a
  /// session out of the view it was in, and that is worth one deliberate answer.
  public func requestArchive(_ id: SessionID) {
    guard let session = sessions.first(where: { $0.id == id }), canArchive(session) else { return }
    pendingArchive = session
  }

  public func cancelArchive() {
    pendingArchive = nil
  }

  /// Archives the session the confirmation was opened for.
  ///
  /// It takes the identifier rather than reading `pendingArchive`, because by the time the
  /// dialog's button runs its action SwiftUI has already dismissed the dialog — and the dismissal
  /// clears `pendingArchive`. Reading it here made Archive do nothing at all.
  public func archive(_ id: SessionID) async {
    pendingArchive = nil
    do {
      let archival = try await archiveSession(id: id)
      report(archival.detachment, for: archival.session, action: .archived)
    } catch {
      // An archive that failed is not a silent no-op. The dialog is already gone, so the banner
      // is the only thing left that can say the session is still where it was.
      await report(error)
    }
    await reload()
    reconcileSelection()
  }

  /// Brings a session back among the current ones, and starts nothing: it comes back closed,
  /// which is what Restart works from.
  public func restore(_ id: SessionID) async {
    do {
      _ = try await restoreSession(id: id)
    } catch {
      await report(error)
    }
    await reload()
    reconcileSelection()
  }

  public func dismissDetachWarning() {
    detachWarning = nil
  }

  // MARK: - Restart

  /// Whether Restart is offered for this session.
  ///
  /// Only a closed session has something to restart: a running one has nothing to resume, and an
  /// archived one has to be unarchived first, deliberately. The command is also withheld from a
  /// session whose restart is already on its way, which is the first of the three locks.
  public func canRestart(_ session: WorkSession) -> Bool {
    guard restartSession != nil, launcher != nil else { return false }
    guard session.status == .closed else { return false }
    guard !restartingSessionIDs.contains(session.id) else { return false }
    // A session whose summary is on screen waiting for an answer is still mid-restart: pressing
    // ⌃⌘R again would build a second plan and replace the question under the user, leaving the
    // text they had started editing attached to nothing.
    guard pendingRestart?.sessionID != session.id else { return false }
    // An agent that cannot run has nothing to restart into, and the ticket asks for the command to
    // be withheld rather than offered and then refused. The answer is the one the detections
    // already left here, so no probe is run to draw a row: a session whose agent has not been
    // resolved yet keeps the command, because "not asked yet" is not "unusable".
    if let resolution = resolutions[session.id], !resolution.isResumable { return false }
    return launcher?.isRunning(session.id) != true
  }

  /// What Restart will do to this session, as far as can be told without building a plan.
  ///
  /// Read from the session and the cached resolution, so a row can say it; the real decision is
  /// `RestartSession`'s, and the two agree because they read the same two facts.
  public func expectedRestartMode(for session: WorkSession) -> String {
    guard case .ready(let descriptor, _) = resolutions[session.id] else {
      return restartTitle(for: session)
    }
    let hasIdentifier = session.agent?.resumeIdentifier?.isEmpty == false
    if hasIdentifier, descriptor.capabilities.supportsResume {
      return "\(restartTitle(for: session)), resuming its \(descriptor.displayName) conversation"
    }
    if session.closedAt == nil {
      return restartTitle(for: session)
    }
    return "\(restartTitle(for: session)) in a new process, with a summary"
  }

  /// A session that was created and never ran is started, not restarted. Promising a restart
  /// there would be a false sentence on the very first use.
  public func restartTitle(for session: WorkSession) -> String {
    session.closedAt == nil ? "Start Session" : "Restart Session"
  }

  /// Restarts a closed session: resumes its conversation when the agent can, and otherwise asks
  /// before starting a second one.
  public func restart(_ id: SessionID) async {
    await performRestart(id: id)
  }

  /// Restarts without resuming, after a resumed conversation failed in front of the user.
  public func restartWithoutResuming(_ id: SessionID) async {
    resumeFailure = nil
    await performRestart(id: id, ignoringResumeIdentifier: true)
  }

  /// Sends the summary the user has read, and possibly edited.
  public func confirmRestart(_ text: String) async {
    guard let pending = pendingRestart else { return }
    pendingRestart = nil
    await performRestart(
      id: pending.sessionID,
      contextOverride: pending.carriesContext ? text : nil,
      // The conversation was already found unresumable when this dialog was built; asking the
      // agent again would only offer it a second chance to be refused.
      ignoringResumeIdentifier: true,
      confirmed: true
    )
  }

  public func cancelRestart() {
    pendingRestart = nil
  }

  public func dismissRestartFailure() {
    restartFailure = nil
  }

  public func dismissResumeFailure() {
    resumeFailure = nil
  }

  private func performRestart(
    id: SessionID,
    contextOverride: String? = nil,
    ignoringResumeIdentifier: Bool = false,
    confirmed: Bool = false
  ) async {
    guard let launcher, let restartSession else { return }
    // A question already asked about this session is not asked twice; answering it is what moves
    // it forward. `restartingSessionIDs` cannot carry this on its own, because the wait for an
    // answer is not work in flight and would hold the lock for as long as the sheet is open.
    guard confirmed || pendingRestart?.sessionID != id else { return }
    // The lock is taken before the first await, and it is what makes a second command — a second
    // click, a shortcut pressed twice — a no-op rather than a second agent.
    guard restartingSessionIDs.insert(id).inserted else { return }
    defer { restartingSessionIDs.remove(id) }

    restartFailure = nil
    do {
      let restart = try await restartSession(
        id: id,
        contextOverride: contextOverride,
        ignoringResumeIdentifier: ignoringResumeIdentifier
      )
      guard !restart.needsConfirmation || confirmed else {
        pendingRestart = PendingRestart(
          sessionID: id,
          sessionName: restart.session.name,
          explanation: restart.explanation?.sentence ?? "",
          briefText: restart.mode.brief?.text ?? "",
          isTruncated: restart.mode.brief?.isTruncated ?? false,
          carriesContext: restart.mode.brief != nil
        )
        return
      }

      if case .native = restart.mode {
        resumeAttempts[id] = clock.now()
      } else {
        resumeAttempts[id] = nil
      }

      let started = await launcher.restart(restart)
      if !started {
        // No process was handed the conversation, so there is no resume to judge: leaving the
        // attempt recorded would let an unrelated close, later on, be read as a refused resume.
        resumeAttempts[id] = nil
        // The pane knows why, when it knows: a terminal that could not be opened says so, and a
        // session that turned out to be running already is simply left alone.
        restartFailure = RestartFailure(
          sessionName: restart.session.name,
          message: launcher.failure(for: id)?.message ?? "This session could not be restarted.",
          suggestion: launcher.failure(for: id)?.suggestion
        )
      }
    } catch let refusal as SessionRestartRefusal {
      restartFailure = RestartFailure(
        sessionName: sessions.first { $0.id == id }?.name ?? "This session",
        message: refusal.errorDescription ?? "This session could not be restarted.",
        suggestion: refusal.recoverySuggestion
      )
    } catch {
      await report(error)
    }
    await reload()
  }

  /// Tells a resumed conversation the agent refused from an ordinary end of work.
  ///
  /// Nothing is relaunched here. A CLI that cannot find the conversation exits in a second or
  /// two, and starting a fresh agent on a summary nobody has read would double the work behind
  /// the user's back; the offer is made instead.
  private func noteProcessDidFinish(_ id: SessionID) {
    guard let startedAt = resumeAttempts[id] else { return }
    guard clock.now().timeIntervalSince(startedAt) < Self.resumeProbation else {
      // Out of the window: an agent that was worked in and quit, which is not this offer's
      // business. The attempt is dropped so a later close cannot be judged against it.
      resumeAttempts[id] = nil
      return
    }
    // The attempt is only consumed once it has actually been judged. A pane that has not caught
    // up with its process yet would otherwise swallow the offer for good.
    guard let status = launcher?.pane(for: id)?.status else { return }
    switch status {
    case .exited(let code):
      // A clean exit is an agent that finished, whatever it was handed.
      guard code != 0 else {
        resumeAttempts[id] = nil
        return
      }
    case .terminated, .failed:
      break
    case .running, .starting:
      return
    }
    resumeAttempts[id] = nil
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    resumeFailure = ResumeFailure(sessionID: id, sessionName: session.name)
  }

  private func report(
    _ detachment: SessionDetachOutcome,
    for session: WorkSession,
    action: DetachWarning.Action
  ) {
    guard case .unreachable(let processIdentifier) = detachment else { return }
    detachWarning = DetachWarning(
      action: action,
      sessionName: session.name,
      processIdentifier: processIdentifier
    )
  }

  public var canCreateSession: Bool {
    agents != nil && launcher != nil
  }

  public var newSessionDefaultWorkingDirectoryPath: String? {
    defaultWorkingDirectoryPath
  }

  public func load() async {
    guard state == .idle else { return }
    // The stored selection is read before the sessions, so the first list that arrives can be
    // asked whether that session still exists instead of selecting its first row and losing it.
    preferredSelection = await layout.restore()
    // Before the sessions, and never from the creation flow: the point of the whole step is that
    // pressing Create leaves nothing left to ask. Reading the store first left a window in which
    // ⌘N opened a sheet that did not yet know whether the access was there, and warned anyway.
    await permissions?.refresh()
    await reload()
    await refreshAgents()
  }

  /// Detection never fails the application: an unavailable agent is data, not an error.
  ///
  /// Each agent is published as its own detection lands, in registration order. Waiting for the
  /// whole set would hold every result behind the slowest one, and a CLI that answers none of its
  /// probes now costs three budgets and their retries: there is no reason for the agents that
  /// answered straight away to stay hidden for that long.
  public func refreshAgents(forceRefresh: Bool = false) async {
    guard let agents, !isRefreshingAgents else { return }

    isRefreshingAgents = true
    defer { isRefreshingAgents = false }

    let descriptors = await agents.descriptors()
    var diagnostics: [AgentProviderID: AgentDiagnostic] = [:]

    await withTaskGroup(of: (AgentProviderID, AgentAvailability?).self) { group in
      for descriptor in descriptors {
        group.addTask {
          guard let provider = await agents.provider(id: descriptor.id) else {
            return (descriptor.id, nil)
          }
          return (descriptor.id, await provider.availability(forceRefresh: forceRefresh))
        }
      }

      for await (id, availability) in group {
        guard let availability else { continue }
        diagnostics[id] = availability.diagnostic
        agentDiagnostics = descriptors.compactMap { diagnostics[$0.id] }
      }
    }

    // A detection that just landed may have turned a session's agent from missing to ready, or
    // the other way round, and the sidebar says so.
    await refreshResolutions()
  }

  public func resolution(for session: WorkSession) async -> SessionAgentResolution {
    guard let agents else { return .unassigned }
    return await ResolveSessionAgent(registry: agents)(for: session)
  }

  /// An explicit selection replaces whatever the previous run had asked for: the user is here
  /// now, and a session that reappears later must not take them away from it.
  public func select(_ id: SessionID?) {
    preferredSelection = nil
    apply(selection: id)
  }

  private func apply(selection id: SessionID?) {
    selectedSessionID = id
    layout.select(id)
  }

  /// Moves through the sidebar in the order it is drawn, and stops at both ends rather than
  /// wrapping: a repeated shortcut should not silently loop back to where it started.
  public func selectNext() {
    let visible = visibleSessions
    guard let index = selectedIndex else {
      select(visible.first?.id)
      return
    }
    guard index + 1 < visible.count else { return }
    select(visible[index + 1].id)
  }

  public func selectPrevious() {
    guard let index = selectedIndex, index > 0 else { return }
    select(visibleSessions[index - 1].id)
  }

  /// How many sessions a shortcut can reach. Past that, the sidebar and its arrow keys are the
  /// honest way around, rather than a second modifier nobody would guess.
  public static let shortcutPositionLimit = 9

  /// Selects the session at a one-based position, for the ⌘1…⌘9 shortcuts. The position is the
  /// row the user is looking at, so it follows the filter rather than the whole store.
  public func select(position: Int) {
    let index = position - 1
    let visible = visibleSessions
    guard visible.indices.contains(index) else { return }
    select(visible[index].id)
  }

  private var selectedIndex: Int? {
    visibleSessions.firstIndex { $0.id == selectedSessionID }
  }

  public func resolution(forID id: SessionID) -> SessionAgentResolution? {
    resolutions[id]
  }

  /// Asks what each listed session's agent can do, once per provider rather than once per
  /// session: the answer depends on the CLI, not on the session, and on a cold cache each of
  /// those questions is a real detection with a real timeout behind it.
  public func refreshResolutions() async {
    guard agents != nil else { return }

    var byProvider: [String: SessionAgentResolution] = [:]
    var resolved: [SessionID: SessionAgentResolution] = [:]
    for session in sessions {
      guard let providerID = session.agent?.providerID else {
        resolved[session.id] = .unassigned
        continue
      }
      if let known = byProvider[providerID] {
        resolved[session.id] = known
        continue
      }
      let answer = await resolution(for: session)
      byProvider[providerID] = answer
      resolved[session.id] = answer
    }
    // A run the next reload replaced must not land last: cancelling it only asks, and these
    // answers describe a session list that has since been thrown away.
    guard !Task.isCancelled else { return }
    resolutions = resolved
  }

  public func pane(for id: SessionID) -> TerminalPaneModel? {
    launcher?.pane(for: id)
  }

  public func launchFailure(for id: SessionID) -> TerminalPaneModel.Failure? {
    launcher?.failure(for: id)
  }

  /// The sheet's model lives here, not in the sheet: SwiftUI may evaluate the presentation
  /// closure more than once, and a draft must survive that without being typed twice.
  public func beginNewSession() {
    guard let agents, canCreateSession else { return }
    newSessionModel = NewSessionModel(
      create: CreateSession(repository: repository, agents: agents),
      registry: agents,
      fullDiskAccess: permissions?.status
    )
    isPresentingNewSession = true
  }

  /// Cancelling leaves nothing behind: no session, no process, and no draft either.
  public func cancelNewSession() {
    isPresentingNewSession = false
    newSessionModel = nil
  }

  /// The order the ticket asks for: the session is already stored, so it is published and
  /// selected first, and only then does anything get started. A launch that fails leaves a
  /// session the user can see and retry, never a disappearing one.
  ///
  /// It is published by inserting it rather than by reloading the store: the session is already
  /// written, so showing it is a fact and not a guess, and the workspace never has to go blank
  /// to display something the application already holds.
  public func complete(_ creation: SessionCreation) async {
    isPresentingNewSession = false
    newSessionModel = nil
    insert(creation.session)
    select(creation.session.id)
    guard let launcher else { return }
    await launcher.launch(session: creation.session, plan: creation.plan)
    await reload()
  }

  /// Reloads, after any reload already under way rather than instead of it.
  ///
  /// Dropping a concurrent request was worse than it looked: a caller that had just written to
  /// the store — archiving a session, say — would return from `reload()` immediately while an
  /// older read, started before that write, went on to commit its stale list. The archive was
  /// done and invisible. Chaining costs one extra read and makes "reload once I am done" true.
  public func reload() async {
    let previous = reloadTask
    let task = Task { @MainActor [weak self] in
      await previous?.value
      await self?.performReload()
    }
    reloadTask = task
    await task.value
  }

  private func performReload() async {
    // A refresh over something already on screen never blanks it. The spinner belongs to the
    // first load, when there is genuinely nothing to show.
    if sessions.isEmpty {
      state = .loading
    }

    let previousSelection = preferredSelection ?? selectedSessionID
    do {
      let sessions = try await loadSessions()
      state = .loaded(sessions)
      refreshFailure = nil
      // A selection restored from a previous run may name a session that has been archived out
      // of the list, or that never came back at all. It falls back instead of blocking the
      // launch on a session that no longer exists.
      //
      // The fallback keeps the restored selection in hand rather than resolving it away: a load
      // that came back empty or short — a store caught mid-write — would otherwise persist the
      // fallback and lose the user's place for good.
      // A facet restored from a previous run can name an agent that has since been uninstalled,
      // or a folder no session uses any more. Dropping it is the difference between an empty
      // sidebar with a reason and one that reads as a lost store.
      //
      // The facets are reconciled against that same load, so they are spared the same way: an
      // empty answer is a store caught mid-write, not a workspace without agents or folders.
      let reconciled = sessions.isEmpty ? layout.filter : layout.filter.reconciled(with: sessions)
      if reconciled != layout.filter {
        layout.setFilter(reconciled)
      }

      if let previousSelection, sessions.contains(where: { $0.id == previousSelection }) {
        preferredSelection = nil
        apply(selection: previousSelection)
      } else if let first = visibleSessions.first {
        apply(selection: first.id)
      }
      // A selection restored from a previous run can name a session this scope does not list —
      // one archived since, or simply closed while the sidebar opens on Active. It falls back to
      // a row the user can actually see, rather than to one the sidebar cannot show as selected.
      reconcileSelection()
      // Not awaited: the sidebar draws perfectly well without knowing what each agent can do,
      // and on a cold cache this is a detection the first frame would otherwise wait for.
      resolutionTask?.cancel()
      resolutionTask = Task { [weak self] in await self?.refreshResolutions() }
    } catch {
      await report(error)
    }
  }

  /// Dismisses the banner. The sessions on screen are the ones the application already holds,
  /// so there is nothing to reload before letting the user get back to work.
  public func dismissRefreshFailure() {
    refreshFailure = nil
  }

  private func insert(_ session: WorkSession) {
    var sessions = sessions.filter { $0.id != session.id }
    sessions.append(session)
    state = .loaded(
      sessions.sorted { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
          return lhs.id.description < rhs.id.description
        }
        return lhs.updatedAt > rhs.updatedAt
      }
    )
  }

  public func restoreBackup() async {
    guard let recovery else { return }

    do {
      try await recovery.restoreBackup()
    } catch {
      await report(error)
      return
    }
    await reload()
  }

  /// A store failure never takes the workspace away.
  ///
  /// With nothing on screen the failure *is* the screen — there is no other way to offer the
  /// backup. With sessions already listed, and possibly an agent running in one of them, it is
  /// a banner over them: a transient read error must not dismantle the terminals or lose the
  /// user's place.
  private func report(_ error: Error) async {
    let message = (error as? LocalizedError)?.errorDescription ?? "Unable to load work sessions."
    let canRestoreBackup = await recovery?.recoveryStatus() == .backupAvailable

    if sessions.isEmpty {
      state = .failed(message: message, canRestoreBackup: canRestoreBackup)
    } else {
      refreshFailure = RefreshFailure(message: message, canRestoreBackup: canRestoreBackup)
    }
  }
}
