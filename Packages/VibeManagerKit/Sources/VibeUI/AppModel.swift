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
  /// Sessions whose conversation the agent gave up on within seconds of being handed it.
  ///
  /// Kept, and acted on at the *next* restart rather than announced when it happens. The news
  /// that a conversation is gone is only useful to someone asking for that session back; as a
  /// banner it arrived over a session the user had just finished with, interrupting them to
  /// report something they had not asked for.
  ///
  /// Held for this run of the application only. A lock left behind by a killed CLI is often gone
  /// by the next launch, and a session refused today deserves one more honest try tomorrow.
  public private(set) var resumeRefusals: Set<SessionID> = []

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

  /// A repository being added to a session, from the panel to the confirmation.
  public private(set) var repositoryAttachment: RepositoryAttachmentModel?
  /// What to tell an agent already running about a repository just added to its session. Shown
  /// with its text, and typed into the terminal only when the user clicks: the first newline in a
  /// pseudo terminal submits a message, and the keyboard there is the user's.
  public private(set) var pendingAddendum: PendingAddendum?
  /// What detaching, preparing again or reordering a repository left to be said.
  public private(set) var repositoryNotice: RepositoryNotice?
  /// What the verification before a launch found and did not stop it for.
  public private(set) var launchWarning: LaunchWarning?
  /// What the agent did to the branches of each session, as last read. Only the session on
  /// screen is read, so the others keep what was true when they were last looked at.
  public private(set) var branchReports: [SessionID: SessionBranchReport] = [:]
  private var branchWatch: (id: SessionID, task: Task<Void, Never>)?

  public struct PendingAddendum: Equatable {
    public let sessionID: SessionID
    public let sessionName: String
    public let text: String
  }

  public struct RepositoryNotice: Equatable {
    public let message: String
    public let suggestion: String?
    /// The command to copy, when the notice is about something left on the disk.
    public let command: String?
  }

  public struct LaunchWarning: Equatable {
    public let sessionName: String
    public let lines: [String]
  }

  /// A restoration under way, from the first session to the last.
  public private(set) var restoration: Restoration?
  /// Sessions an unexpected stop left behind, offered rather than resumed.
  public private(set) var restoreOffer: RestoreOffer?
  /// Another copy of the application holds these sessions. Nothing was reconciled, nothing taken.
  public private(set) var otherInstanceProcessIdentifier: Int32?
  /// What did not come back, once the queue is done. `nil` when everything did: a restoration
  /// that worked has nothing to say and says nothing.
  public private(set) var restoreReport: RestoreReport?

  /// The offer's own intention, held here rather than rebuilt from the screen: it was consumed
  /// from the runtime document at launch, and there is nowhere left to read it from.
  private var offeredRestoreIntent: SessionRestoreIntent?
  private var restoreTask: Task<Void, Never>?
  /// Whether the launch sequence has already been run, set before anything suspends.
  private var hasLoaded = false

  /// Where a restoration has got to.
  public struct Restoration: Equatable {
    public let total: Int
    public let completed: Int
    public let currentSessionID: SessionID?
    public let currentName: String?

    public var message: String {
      guard let currentName else {
        return "Restoring sessions — \(completed) of \(total)"
      }
      return "Restoring sessions — \(min(completed + 1, total)) of \(total) · \(currentName)"
    }
  }

  /// An unexpected stop, and what it left running.
  ///
  /// The sessions are offered, not resumed: a crash is not an intention, and the agent that was
  /// running may be what brought the application down. Relaunching it unattended would start the
  /// same fall again, with more agents in it each time.
  public struct RestoreOffer: Equatable {
    public let sessionCount: Int
    /// Process groups of the previous run that answer but cannot be identified. Reported,
    /// deliberately never signalled: pids are recycled.
    public let leftoverProcessIdentifiers: [Int32]
    public let interruptedAt: Date?

    public var message: String {
      let subject =
        sessionCount == 1 ? "1 session was running" : "\(sessionCount) sessions were running"
      return "Vibe Manager stopped unexpectedly. \(subject)."
    }

    public var suggestion: String? {
      guard !leftoverProcessIdentifiers.isEmpty else { return nil }
      let pids = leftoverProcessIdentifiers.map(String.init).joined(separator: ", ")
      return """
        A process from that run may still be running (pid \(pids)) and was left alone; check \
        Activity Monitor.
        """
    }
  }

  /// What a restoration left for the user to deal with, in one place.
  ///
  /// A list and not a dialog, and above all not one dialog per session: five modal questions at
  /// launch is an application nobody can use.
  public struct RestoreReport: Equatable {
    public struct Line: Equatable, Identifiable {
      public let id: SessionID
      public let name: String
      public let sentence: String
      public let suggestion: String?
    }

    public let restartedCount: Int
    public let cancelledCount: Int
    public let lines: [Line]

    /// What the banner says. Cancelling is an answer, not a failure, so it has a sentence of its
    /// own rather than a list of lines: the user knows they stopped it, and what they do not know
    /// is how many sessions that left closed.
    public var message: String {
      var sentences: [String] = []
      if !lines.isEmpty {
        sentences.append(
          lines.count == 1
            ? "1 session did not come back." : "\(lines.count) sessions did not come back.")
      }
      if cancelledCount > 0 {
        sentences.append(
          cancelledCount == 1
            ? "1 more was left closed when you cancelled."
            : "\(cancelledCount) more were left closed when you cancelled."
        )
      }
      if restartedCount > 0 {
        sentences.append(
          restartedCount == 1 ? "1 session came back." : "\(restartedCount) sessions came back.")
      }
      return sentences.joined(separator: " ")
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

  let repository: any SessionRepository
  private let loadSessions: LoadSessions
  private let recovery: (any SessionStoreRecovery)?
  private let agents: (any AgentProviderResolving)?
  let launcher: SessionLauncher?
  private let defaultWorkingDirectoryPath: String?
  private let closeSession: CloseSession
  private let archiveSession: ArchiveSession
  private let restoreSession: RestoreSession
  private let restartSession: RestartSession?
  private let detectPreviousShutdown: DetectPreviousShutdown?
  private let restoreSessions: RestoreSessions?
  let clock: any SessionClock
  let workspace: SessionWorkspaceServices?
  private let readBranchReport: ReadSessionBranchReport?
  let captureBaseline: CaptureSessionBaseline?
  /// How often the branches of the session on screen are read again while its agent runs.
  private let branchReportInterval: Duration
  private let detachRepository: DetachRepository
  private let makeMainRepository: MakeMainRepository

  public init(
    repository: any SessionRepository,
    recovery: (any SessionStoreRecovery)? = nil,
    agents: (any AgentProviderResolving)? = nil,
    launcher: SessionLauncher? = nil,
    defaultWorkingDirectoryPath: String? = nil,
    layout: WorkspaceLayoutController = WorkspaceLayoutController(),
    permissions: PermissionsModel? = nil,
    /// Where the previous run wrote what it was running. Absent in a workspace assembled without
    /// the system around it, and nothing is then detected or restored at launch.
    runtimeRecorder: SessionRuntimeRecorder? = nil,
    processes: any ProcessLivenessProbe = SystemProcessLivenessProbe(),
    // Only the resume probation reads it, and it is the one rule here measured in seconds of real
    // time: without a clock to move, its far side could only be tested by waiting eight seconds.
    clock: any SessionClock = SystemSessionClock(),
    /// Git and the worktree root. Absent in a workspace assembled without them, where every
    /// folder is attached in place and nothing can be added afterwards.
    workspace: SessionWorkspaceServices? = nil,
    branchReportInterval: Duration = .seconds(30)
  ) {
    self.clock = clock
    self.workspace = workspace
    self.branchReportInterval = branchReportInterval
    readBranchReport = workspace?.activity.map {
      ReadSessionBranchReport(reader: $0, transcripts: workspace?.transcripts, clock: clock)
    }
    captureBaseline = workspace?.activity.map {
      CaptureSessionBaseline(repository: repository, reader: $0)
    }
    detachRepository = DetachRepository(repository: repository, clock: clock)
    makeMainRepository = MakeMainRepository(repository: repository, clock: clock)
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
    let restart = agents.map {
      RestartSession(repository: repository, agents: $0, workspace: workspace)
    }
    restartSession = restart
    // The two halves of #11: what the previous run left behind, and the queue that honours it.
    // Both are absent together, because a workspace that cannot launch has nothing to restore.
    detectPreviousShutdown = runtimeRecorder.map {
      DetectPreviousShutdown(
        repository: repository, recorder: $0, processes: processes, clock: clock)
    }
    restoreSessions =
      launcher.flatMap { launcher in
        restart.map {
          RestoreSessions(restart: $0, launcher: launcher, repository: repository)
        }
      }

    launcher?.sessionDidClose = { [weak self] id, state in
      guard let self else { return }
      self.noteProcessDidFinish(id, state: state)
      // Once more when the agent stops: its last commits are the ones the user wants to see.
      if self.selectedSessionID == id {
        Task { await self.readBranches(of: id) }
      }
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
  /// Keeps the user with a session whose new status has moved it to the other tab.
  ///
  /// The sidebar is split on whether an agent is running, so a session put back to work leaves
  /// Closed the moment it starts. Left alone, the session the user just restarted would vanish
  /// from the list under their pointer and the selection would fall to whatever row took its
  /// place. The scope follows the session instead, and the session stays selected.
  ///
  /// Only the scope is moved. A search or a facet that also hides it is a narrowing the user
  /// typed themselves, and clearing it would undo work they can see.
  private func follow(_ id: SessionID) {
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    if !filter.scope.includes(session.status),
      let scope = SessionScope.allCases.first(where: { $0.includes(session.status) })
    {
      update { $0.scope = scope }
    }
    select(id)
  }

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
    // A session that has never run has nothing to resume and nothing to summarise: it gets its
    // own prompt, and the sentence says only that it is being started.
    if !session.hasEverStarted {
      return restartTitle(for: session)
    }
    // Trimmed, exactly as `RestartSession` trims it: an identifier of whitespace is not one, and
    // promising a resume this row cannot deliver is worse than saying nothing.
    let identifier = session.agent?.resumeIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if identifier?.isEmpty == false, descriptor.capabilities.supportsResume,
      !resumeRefusals.contains(session.id)
    {
      return "\(restartTitle(for: session)), resuming its \(descriptor.displayName) conversation"
    }
    return "\(restartTitle(for: session)) in a new process, with a summary"
  }

  /// A session that was created and never ran is started, not restarted. Promising a restart
  /// there would be a false sentence on the very first use.
  public func restartTitle(for session: WorkSession) -> String {
    session.hasEverStarted ? "Restart Session" : "Start Session"
  }

  /// Restarts a closed session: resumes its conversation when the agent can, and otherwise asks
  /// before starting a second one.
  public func restart(_ id: SessionID) async {
    await performRestart(id: id)
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
      skippingResume: .alreadyAnswered,
      confirmed: true
    )
  }

  public func cancelRestart() {
    pendingRestart = nil
  }

  public func dismissRestartFailure() {
    restartFailure = nil
  }

  private func performRestart(
    id: SessionID,
    contextOverride: String? = nil,
    skippingResume: SessionResumeSkip? = nil,
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
        // A conversation this agent already dropped is not handed back. The user is told so in
        // the summary they are about to read, which is where the news belongs: at the moment
        // they ask for the session again, not as a banner over the one they just closed.
        skippingResume: skippingResume ?? (resumeRefusals.contains(id) ? .failedLastTime : nil)
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

      launchWarning =
        restart.warnings.isEmpty
        ? nil : LaunchWarning(sessionName: restart.session.name, lines: restart.warnings)
      switch await launcher.restart(restart) {
      case .started:
        switch restart.mode {
        case .firstLaunch, .freshWithContext, .freshWithoutContext:
          // The refusal has been acted on, and this process starts a conversation of its own.
          // Kept any longer it would skip the resume of an identifier that has since been
          // replaced.
          resumeRefusals.remove(id)
        case .native:
          // A resume that was refused *while this very call was in flight* records its refusal
          // before the launch returns — the process is already gone by then. Clearing it here
          // because the launch "succeeded" handed the same dead conversation back at the next
          // restart, and the user was never told why their session would not come up.
          break
        }
      case .alreadyRunning:
        // The agent the user asked for is up; another path got there first. Nothing was handed a
        // conversation here, so the attempt is dropped — and no failure is reported over a
        // session that is running perfectly well.
        resumeAttempts[id] = nil
      case .failed(let reason):
        // No process was handed the conversation, so there is no resume to judge: leaving the
        // attempt recorded would let an unrelated close, later on, be read as a refused resume.
        resumeAttempts[id] = nil
        // The launcher's own reason first — it knows about a store that refused, which the pane
        // cannot say — and the pane's next, for a terminal that would not open.
        let failure = launcher.failure(for: id)
        restartFailure = RestartFailure(
          sessionName: restart.session.name,
          message: reason ?? failure?.message ?? "This session could not be restarted.",
          suggestion: reason == nil ? failure?.suggestion : nil
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
    // Whether it started or not: a restart that succeeded moved the session to Active, and one
    // that failed left it where it was, which this simply confirms.
    follow(id)
  }

  /// Tells a resumed conversation the agent refused from an ordinary end of work.
  ///
  /// Nothing is relaunched, and nothing is announced. The fact is kept, and the next restart of
  /// that session is what acts on it: a CLI that cannot find the conversation exits in a second
  /// or two, but the person watching has just finished with that session, and a banner there
  /// interrupts them with news they can do nothing useful with yet.
  private func noteProcessDidFinish(_ id: SessionID, state: TerminalProcessState) {
    guard let startedAt = resumeAttempts[id] else { return }
    resumeAttempts[id] = nil
    guard clock.now().timeIntervalSince(startedAt) < Self.resumeProbation else {
      // Out of the window: an agent that was worked in and quit, which is not this offer's
      // business.
      return
    }
    if let pane = launcher?.pane(for: id) {
      // An agent somebody typed into resumed its conversation perfectly well, and an agent this
      // application killed was answering Close, not refusing anything. Either way the exit says
      // nothing about the resume — and calling it a refused one told the user their session had
      // lost its conversation when they had simply closed it.
      guard !pane.hasReceivedInput, !pane.wasStoppedOnPurpose else { return }
    }
    // The state the process actually ended in, handed over by the launcher. Read back from the
    // pane it was a race: the pane is driven by its own attachment, and one that had not caught
    // up yet answered "still running" about a process that had already exited — and the offer
    // was then dropped for good.
    switch state {
    case .exited(let code):
      // A clean exit is an agent that finished, whatever it was handed.
      guard code != 0 else { return }
    case .terminated, .failed:
      break
    case .running, .starting:
      // Not an ending at all, so there is nothing to judge.
      return
    }
    resumeRefusals.insert(id)
  }

  // MARK: - Restoration at launch

  /// Whether this session is the one the restoration is working on right now.
  public func isRestoring(_ id: SessionID) -> Bool {
    restoration?.currentSessionID == id
  }

  /// Resumes the sessions an unexpected stop left behind, now that the user has asked.
  public func acceptRestoreOffer() async {
    guard let intent = offeredRestoreIntent else { return }
    restoreOffer = nil
    offeredRestoreIntent = nil
    await beginRestore(intent)
  }

  /// Declines the offer. Nothing is lost that was not already: the sessions are closed, whole,
  /// and one Restart away.
  public func dismissRestoreOffer() {
    restoreOffer = nil
    offeredRestoreIntent = nil
  }

  public func dismissRestoreReport() {
    restoreReport = nil
  }

  public func dismissOtherInstanceNotice() {
    otherInstanceProcessIdentifier = nil
  }

  /// Empties the queue. What is already running keeps running: stopping an agent that has just
  /// been handed its conversation back, to honour a cancellation, would destroy the very work
  /// this was restoring.
  public func cancelRestore() {
    restoreTask?.cancel()
  }

  /// Calls off a restoration and waits for the session in flight to finish being launched.
  ///
  /// Quitting needs this rather than `cancelRestore`: cancelling only asks, and a resume already
  /// under way goes on to write `reopen`. That write landing after the shutdown had read what to
  /// close left a session stored active, never detached, absent from the intention to resume it,
  /// with a process only the supervisor's last sweep took down.
  public func stopRestoring() async {
    guard let task = restoreTask else { return }
    task.cancel()
    await task.value
  }

  /// What the verdict has to say straight away, before anything is probed or launched.
  private func announce(_ shutdown: PreviousShutdown?) {
    switch shutdown {
    case .otherInstance(let processIdentifier):
      otherInstanceProcessIdentifier = processIdentifier
    case .unexpected(let intent, let leftovers):
      offeredRestoreIntent = intent
      restoreOffer = RestoreOffer(
        sessionCount: intent.sessionIDs.count,
        leftoverProcessIdentifiers: leftovers.compactMap(\.processGroup),
        interruptedAt: intent.interruptedAt
      )
    case .none, .nothingToDo, .clean:
      return
    }
  }

  /// The one verdict that puts sessions back to work by itself.
  private func resume(_ shutdown: PreviousShutdown?) async {
    guard case .clean(let intent) = shutdown else { return }
    await beginRestore(intent)
  }

  private func beginRestore(_ intent: SessionRestoreIntent) async {
    guard let restoreSessions, !intent.isEmpty else { return }
    restoreReport = nil
    restoration = Restoration(
      total: intent.sessionIDs.count,
      completed: 0,
      currentSessionID: nil,
      currentName: nil
    )

    // A queue already under way is called off rather than overwritten: its task would otherwise
    // go on launching sessions with nobody holding it, and Cancel would only ever reach the last
    // one started.
    restoreTask?.cancel()

    // Run from a task of its own so that Cancel has something to cancel: the queue checks for
    // cancellation between two sessions, which is the only place where stopping costs nothing.
    let task = Task { @MainActor [weak self] in
      let outcomes = await restoreSessions(intent) { progress in
        self?.note(progress)
      }
      await self?.finishRestore(with: outcomes)
    }
    restoreTask = task
    await task.value
  }

  private func note(_ progress: SessionRestoreProgress) {
    switch progress {
    case .started(let id, let name, let index, let total):
      restoration = Restoration(
        total: total,
        completed: index - 1,
        currentSessionID: id,
        currentName: name
      )
    case .finished:
      guard let current = restoration else { return }
      restoration = Restoration(
        total: current.total,
        completed: min(current.completed + 1, current.total),
        currentSessionID: nil,
        currentName: nil
      )
    }
  }

  /// Internal rather than private: the mapping from outcomes to what the user reads is the part
  /// of this worth holding to its wording, and it is reached from nowhere else.
  func finishRestore(with outcomes: [SessionRestoreOutcome]) async {
    restoration = nil
    restoreTask = nil

    let lines = outcomes.compactMap { outcome -> RestoreReport.Line? in
      guard let sentence = outcome.sentence else { return nil }
      return RestoreReport.Line(
        id: outcome.sessionID,
        name: outcome.sessionName,
        sentence: sentence,
        suggestion: outcome.suggestion
      )
    }
    // Silence on success, and only on success. A restoration where everything came back has
    // nothing to say; one the user called off has left sessions closed, and how many is exactly
    // what they cannot see for themselves.
    let cancelledCount = outcomes.filter(\.wasCancelled).count
    restoreReport =
      lines.isEmpty && cancelledCount == 0
      ? nil
      : RestoreReport(
        restartedCount: outcomes.filter(\.didRestart).count,
        cancelledCount: cancelledCount,
        lines: lines
      )
    // Every session that came back had `reopen` written for it while the list on screen was the
    // one loaded before the queue started.
    await reload()
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
    // Taken synchronously, before the first `await`. `state` only becomes `.loading` inside the
    // reload, several suspensions later, so two loads — a second window, a `.task` run twice —
    // both passed that guard, both detected the previous shutdown before either had claimed the
    // runtime document, and both started a restoration of the same sessions.
    guard !hasLoaded else { return }
    hasLoaded = true
    // The stored selection is read before the sessions, so the first list that arrives can be
    // asked whether that session still exists instead of selecting its first row and losing it.
    preferredSelection = await layout.restore()
    // Before the sessions, and never from the creation flow: the point of the whole step is that
    // pressing Create leaves nothing left to ask. Reading the store first left a window in which
    // ⌘N opened a sheet that did not yet know whether the access was there, and warned anyway.
    await permissions?.refresh()
    // Before the first list, because it is what makes that list true: a session the previous run
    // left `active` has nothing running behind it, and drawing it as running once — even for one
    // frame — is the lie this whole ticket is about.
    let shutdown = await detectPreviousShutdown?()
    await reload()
    // Said as soon as the list is on screen. An offer asks no provider anything, and waiting for
    // the detections to announce it meant a minute of silence after a crash — on a cold cache,
    // with a CLI that answers none of its probes, the banner arrived long after the user had
    // decided the application had forgotten their sessions.
    announce(shutdown)
    // The restoration, on the other hand, waits: each resume asks its provider whether it can
    // run, and a queue started before the probes had answered would pay for that answer session
    // by session, with a progress bar in front of the user.
    await refreshAgents()
    await resume(shutdown)
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
    watchBranches()
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
      create: CreateSession(repository: repository, agents: agents, workspace: workspace),
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
    guard let plan = creation.plan else {
      // The session exists, with what happened to its main repository; nothing was started, and
      // the banner says why and what to do about it.
      restartFailure = RestartFailure(
        sessionName: creation.session.name,
        message: creation.launchRefusal?.errorDescription ?? "The session could not be started.",
        suggestion: creation.launchRefusal?.recoverySuggestion
      )
      await reload()
      return
    }
    report(preparationOf: creation.session)
    await launcher.launch(session: creation.session, plan: plan)
    await reload()
    // A session created while the sidebar was on Closed is running by now, and it is the one the
    // user is looking at: the tab follows it rather than hiding what they just made.
    follow(creation.session.id)
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
  func report(_ error: Error) async {
    let message = (error as? LocalizedError)?.errorDescription ?? "Unable to load work sessions."
    let canRestoreBackup = await recovery?.recoveryStatus() == .backupAvailable

    if sessions.isEmpty {
      state = .failed(message: message, canRestoreBackup: canRestoreBackup)
    } else {
      refreshFailure = RefreshFailure(message: message, canRestoreBackup: canRestoreBackup)
    }
  }
}

// MARK: - Repositories

extension AppModel {
  public var canEditRepositories: Bool { workspace != nil }

  /// Opens the attachment of one more repository to a session, once a folder is designated.
  public func beginAttachRepository(to id: SessionID, path: String) async {
    guard let workspace, let session = sessions.first(where: { $0.id == id }) else { return }
    let model = RepositoryAttachmentModel(
      sessionID: id,
      sessionName: session.name,
      attach: AttachRepository(repository: repository, services: workspace, clock: clock),
      isRunning: { [weak self] in self?.launcher?.isRunning(id) ?? false }
    )
    repositoryAttachment = model
    await model.folderChosen(path)
  }

  public func cancelAttachRepository() {
    repositoryAttachment = nil
  }

  /// Prepares and attaches the repository the sheet shows, then offers the addendum to a running
  /// agent — offers it, and nothing more.
  public func confirmAttachRepository() async {
    guard let model = repositoryAttachment, let attachment = await model.confirm() else { return }
    repositoryAttachment = nil
    if let text = attachment.addendum {
      pendingAddendum = PendingAddendum(
        sessionID: attachment.session.id,
        sessionName: attachment.session.name,
        text: text
      )
    }
    if attachment.addendum != nil, let captureBaseline {
      // Attached while its agent runs: what happens in it from now on is part of the report.
      await captureBaseline(sessionID: attachment.session.id)
    }
    if let failure = attachment.repository.failure {
      repositoryNotice = RepositoryNotice(
        message:
          "\(attachment.repository.displayName) was attached, but not prepared: \(failure.message)",
        suggestion: failure.remedy,
        command: nil
      )
    }
    await reload()
  }

  /// Types the addendum into the session's terminal, as a paste followed by Return. Only ever
  /// called from the button that shows the text.
  public func sendAddendum() async {
    guard let addendum = pendingAddendum else { return }
    pendingAddendum = nil
    guard let pane = launcher?.pane(for: addendum.sessionID),
      launcher?.isRunning(addendum.sessionID) == true
    else { return }
    // Bracketed paste: the agent's composer takes the whole text as one message, newlines and
    // all, instead of submitting it at its first line.
    let pasted = "\u{1B}[200~" + addendum.text + "\u{1B}[201~"
    await pane.write(Array(pasted.utf8))
    await pane.write(Array("\r".utf8))
  }

  public func dismissAddendum() {
    pendingAddendum = nil
  }

  public func dismissRepositoryNotice() {
    repositoryNotice = nil
  }

  public func dismissLaunchWarning() {
    launchWarning = nil
  }

  /// Forgets a repository. The worktree and the branch stay where they are; the notice gives the
  /// command that would remove them, for the user to run if they decide to.
  public func detach(repository repositoryID: RepositoryID, from id: SessionID) async {
    do {
      let detachment = try await detachRepository(sessionID: id, repositoryID: repositoryID)
      var message =
        "\(detachment.repository.displayName) was detached. Nothing on disk was removed."
      if detachment.changedMainRepository {
        message +=
          launcher?.isRunning(id) == true
          ? " The next repository is now the main one; the running agent stays where it was started."
          : " The next repository is now the main one."
      }
      repositoryNotice = RepositoryNotice(
        message: message,
        suggestion: detachment.cleanupCommand == nil
          ? nil : "To remove what it left, run this yourself:",
        command: detachment.cleanupCommand
      )
    } catch {
      await report(error)
    }
    await reload()
  }

  /// Prepares a repository again — the remedy for a worktree that disappeared or never came.
  public func recreate(repository repositoryID: RepositoryID, in id: SessionID) async {
    guard let workspace else { return }
    do {
      let repaired = try await RepairRepository(
        repository: repository, services: workspace, clock: clock
      )(sessionID: id, repositoryID: repositoryID)
      if let failure = repaired.failure {
        repositoryNotice = RepositoryNotice(
          message: "\(repaired.displayName) could not be prepared: \(failure.message)",
          suggestion: failure.remedy,
          command: nil
        )
      } else {
        repositoryNotice = nil
      }
    } catch {
      await report(error)
    }
    await reload()
  }

  public func makeMain(repository repositoryID: RepositoryID, in id: SessionID) async {
    do {
      try await makeMainRepository(sessionID: id, repositoryID: repositoryID)
      if launcher?.isRunning(id) == true {
        repositoryNotice = RepositoryNotice(
          message: "The main repository changed. The running agent stays where it was started.",
          suggestion: "It will start in the new main repository at the next restart.",
          command: nil
        )
      }
    } catch {
      await report(error)
    }
    await reload()
  }

  /// Says, once the session exists, which of its repositories were not prepared. The session is
  /// usable anyway; these are the ones to come back to.
  func report(preparationOf session: WorkSession) {
    let failed = session.repositories.filter { $0.failure != nil }
    guard !failed.isEmpty else { return }
    launchWarning = LaunchWarning(
      sessionName: session.name,
      lines: failed.map { "\($0.displayName) was not prepared: \($0.failure?.message ?? "")" }
    )
  }
}

// MARK: - Branch report

extension AppModel {
  public func branchReport(for id: SessionID) -> SessionBranchReport? {
    branchReports[id]
  }

  public var reportsBranches: Bool { readBranchReport != nil }

  /// Reads the branches of the session on screen now, then every thirty seconds for as long as
  /// its agent runs. Only that session: reading twenty repositories that nobody is looking at
  /// would cost the disk for nothing.
  func watchBranches() {
    guard readBranchReport != nil, let id = selectedSessionID else {
      branchWatch?.task.cancel()
      branchWatch = nil
      return
    }
    // A reload re-applies the same selection; a watch already on it is left alone.
    if let branchWatch, branchWatch.id == id, !branchWatch.task.isCancelled { return }
    branchWatch?.task.cancel()
    let interval = branchReportInterval
    let task = Task { [weak self] in
      while !Task.isCancelled {
        await self?.readBranches(of: id)
        guard let self, self.launcher?.isRunning(id) == true else { break }
        try? await Task.sleep(for: interval)
      }
      // Finished rather than cancelled: the next selection or start watches again.
      if let self, self.branchWatch?.id == id { self.branchWatch = nil }
    }
    branchWatch = (id, task)
  }

  public func refreshBranchReport() async {
    guard let id = selectedSessionID else { return }
    await readBranches(of: id)
    watchBranches()
  }

  func readBranches(of id: SessionID) async {
    guard let readBranchReport, let session = sessions.first(where: { $0.id == id }) else {
      return
    }
    let report = await readBranchReport(for: session)
    guard !Task.isCancelled else { return }
    branchReports[id] = report
  }
}
