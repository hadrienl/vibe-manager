import Foundation
import Observation
import VibeApplication
import VibeBrowser
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

  public private(set) var state: State = .idle {
    // Every list the workspace holds — a reload, a session just created — is the journal's too:
    // it follows the active sessions, and gives one that stopped its last pass.
    didSet {
      if case .loaded(let sessions) = state { journal?.track(sessions) }
    }
  }
  public private(set) var refreshFailure: RefreshFailure?
  public private(set) var agentDiagnostics: [AgentDiagnostic] = []
  /// The name of each detected agent, by provider identifier, for the places that name one.
  public var agentNames: [String: String] {
    Dictionary(
      agentDiagnostics.map { ($0.providerID.rawValue, $0.providerName) },
      uniquingKeysWith: { first, _ in first })
  }
  public private(set) var isRefreshingAgents = false
  public private(set) var selectedSessionID: SessionID?
  public private(set) var isPresentingNewSession = false
  public private(set) var newSessionModel: NewSessionModel?
  /// What each session's agent can do right now, refreshed with the detections. Held here so
  /// that the sidebar and the inspector read the same answer instead of each probing again.
  public private(set) var resolutions: [SessionID: SessionAgentResolution] = [:]
  /// What each session's agent is doing, as the tracker last said (#45).
  public internal(set) var activities: [SessionID: AgentActivityState] = [:]
  /// A CLI's hooks waiting for the user's consent before its agent starts.
  public internal(set) var hookConsentRequest: HookConsentRequest?
  /// The agents whose CLI makes the user approve hooks, for the setting that turns them off.
  public internal(set) var hookTrustingAgents: [AgentDescriptor] = []
  /// Whether each of those agents reports its activity, as the setting shows it.
  public internal(set) var reportsActivity: [AgentProviderID: Bool] = [:]
  let activityTracker: TrackAgentActivity?
  let hookConsents: any AgentHookConsentStore
  /// Every launch waiting on the consent sheet. One answer settles them all.
  var hookConsentWaiters: [UUID: CheckedContinuation<AgentHookConsent, Never>] = [:]
  var activityUpdates: Task<Void, Never>?
  var isApplicationActive = true
  var isMainWindowVisible = true
  /// What the agent did to the branches of each session, as last read. Only the session on
  /// screen is read, so the others keep what was true when they were last looked at.
  public private(set) var branchReports: [SessionID: SessionBranchReport] = [:]
  /// What `git status` says of each repository of each session, as last read. The session on
  /// screen is kept live by the monitor; the others keep what was true when they left it.
  public private(set) var repositoryStatuses: [RepositoryStatusKey: RepositoryStatusState] = [:]
  /// The session whose repositories are watched: the one on screen, and only that one.
  private var observedSessionID: SessionID?
  /// Branch reports being read, and those asked for again during that reading. A burst of
  /// commits costs two readings of the report, not one per commit.
  private var reportReadings: [SessionID: Task<Void, Never>] = [:]
  private var pendingReports: Set<SessionID> = []
  private var statusUpdates: Task<Void, Never>?
  /// The last stop sent to the monitor, which the next one and every `observe` wait for.
  private var pendingStop: Task<Void, Never>?

  /// The session the user asked to archive, held until they confirm. Archiving is reversible,
  /// but it moves a session out of sight, and a slip of the pointer must not do that.
  public private(set) var pendingArchive: WorkSession?
  /// The session the user asked to close while its agent was still working, held until they
  /// confirm. Closing can be undone with Restart, but the agent's work in progress cannot.
  public private(set) var pendingClose: WorkSession?
  /// Closes under way, from the command to the reload that shows the session closed. Until then
  /// the session still reads as running, and a second ⌘W would stop it a second time.
  public private(set) var closingSessionIDs: Set<SessionID> = []
  /// Sessions the user closed, taken off the Active list the moment they asked. Stopping the
  /// agent happens behind it, and nothing of it is theirs to watch. Kept apart from
  /// `closingSessionIDs`, which an agent switch also sets while the session stays on screen.
  private var dismissedSessionIDs: Set<SessionID> = []
  /// Whether closing a session whose agent runs asks first. Mirrored here so that the settings
  /// window and the dialog's "Don't ask again" read and change the same answer.
  public var confirmsStoppingRunningAgent: Bool {
    didSet { closePreferences.confirmsStoppingRunningAgent = confirmsStoppingRunningAgent }
  }
  /// What quitting does to running agents, when the user asked not to be asked again. Mirrored
  /// here so that the settings window and the question's "Don't ask again" change the same answer.
  public var quitBehavior: QuitBehavior {
    didSet { quitPreferences.behavior = quitBehavior }
  }
  /// Where a changed file listed in the inspector opens. `nil`: it is only revealed. Mirrored
  /// here so that the settings window and the inspector read and change the same answer.
  public var fileEditor: EditorChoice? {
    didSet {
      fileOpeningPreferences.editor = fileEditor
      gitInspector.editor = fileEditor
      journal?.editor = fileEditor
    }
  }
  /// The screen state of the inspector's Git pane, kept per session for the length of the run.
  let gitInspector: GitInspectorModel
  /// Every session's notes: the editor's documents, the writes, the search index.
  public let notes: NotesModel
  /// Every session's journal: its summary and its resources (#36). Absent in a workspace
  /// assembled without it.
  public let journal: SessionJournalModel?
  /// The prompt templates, shared by their settings tab and the New Session sheet.
  public let templates: PromptTemplateLibraryModel
  /// The usage figures (#18). Absent in a workspace assembled without them.
  public let usage: UsageModel?
  /// The tab the settings show, so that a way into them — Manage… in the New Session sheet, the
  /// menu — can open them on the right one.
  public var settingsTab: SettingsTab = .general
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
    }

    public let action: Action
    public let sessionName: String
    public let processIdentifier: Int32

    public var message: String {
      let pid = String(processIdentifier)
      switch action {
      case .closed:
        return String(
          localized: """
            \(sessionName) was closed, but its process (pid \(pid)) did not answer the stop and \
            may still be running.
            """,
          bundle: .module, comment: "A session's name, then a process identifier.")
      case .archived:
        return String(
          localized: """
            \(sessionName) was archived, but its process (pid \(pid)) did not answer the stop and \
            may still be running.
            """,
          bundle: .module, comment: "A session's name, then a process identifier.")
      }
    }

    public var suggestion: String {
      String(localized: "Check Activity Monitor for a leftover process.", bundle: .module)
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
    /// Said when the session's notes did not fit in the summary.
    public let leftOutNotes: String?
  }

  public struct RestartFailure: Equatable {
    public let sessionName: String
    public let message: String
    public let suggestion: String?
    /// The session it is about. The banner outlives the selection, so its buttons act on this one
    /// rather than on whichever session is on screen by the time they are pressed.
    public var sessionID: SessionID?
  }

  /// The Switch Agent sheet, while it is open.
  public private(set) var pendingSwitch: AgentSwitchModel?
  /// A switch that did not happen, and why. Nothing was lost by it: the session is left on the
  /// agent it had, and says so.
  public private(set) var switchFailure: RestartFailure?
  /// The agent a session was switched away from, offered back when the new one stopped within
  /// seconds of starting without anybody using it — a model the account may not run, a CLI that
  /// is not signed in. The pane shows why; the bar above it offers the way back.
  public private(set) var switchBackOffers: [SessionID: SwitchBack] = [:]
  /// When each switch started its agent, kept only long enough to tell a quick failure.
  private var switchAttempts: [SessionID: (date: Date, previous: SwitchBack)] = [:]

  public struct SwitchBack: Equatable {
    public let target: AgentTarget
    public let label: String
  }

  /// A restoration under way, from the first session to the last.
  public private(set) var restoration: Restoration?
  /// Sessions an unexpected stop left behind, offered rather than resumed.
  public private(set) var restoreOffer: RestoreOffer?
  /// Another copy of the application holds these sessions. Nothing was reconciled, nothing taken.
  public private(set) var otherInstanceProcessIdentifier: Int32?
  /// Agents that kept running while the application was closed, taken back at launch.
  public private(set) var detachedNotice: DetachedNotice?
  /// Agents left running whose host is alive but would not let this copy reattach. Why, as the
  /// host or the attempt said it.
  public private(set) var hostUnavailableReason: String?
  /// Set while a retry is under way, so the button cannot start a second one.
  public private(set) var isRetryingHost = false
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
        return String(
          localized: "Restoring sessions — \(completed) of \(total)", bundle: .module,
          comment: "Progress of the restoration: sessions done, then sessions in all.")
      }
      return String(
        localized:
          "Restoring sessions — \(min(completed + 1, total)) of \(total) · \(currentName)",
        bundle: .module,
        comment:
          "Progress of the restoration: the session being restored, of how many, and its name.")
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
      String(
        localized: "Vibe Manager stopped unexpectedly. \(sessionCount) sessions were running.",
        bundle: .module)
    }

    public var suggestion: String? {
      guard !leftoverProcessIdentifiers.isEmpty else { return nil }
      let pids = leftoverProcessIdentifiers.map(String.init).joined(separator: ", ")
      return String(
        localized: """
          A process from that run may still be running (pid \(pids)) and was left alone; check \
          Activity Monitor.
          """,
        bundle: .module, comment: "Process identifiers, separated by commas.")
    }
  }

  /// Agents left running when the application quit, found again at launch.
  ///
  /// Said, not asked: the user chose to leave them, and they are already back on screen. It is
  /// the one place the application admits it was not watching while they worked.
  public struct DetachedNotice: Equatable {
    public let runningCount: Int
    public let endedCount: Int

    public var message: String {
      let total = runningCount + endedCount
      // One count per sentence can agree with its noun: past one ended agent, both counts are
      // plural, and only the total is left to agree.
      switch endedCount {
      case 0:
        return String(
          localized: "\(total) agents kept running while Vibe Manager was closed.",
          bundle: .module)
      case 1:
        return String(
          localized:
            "\(total) agents kept running while Vibe Manager was closed; 1 has finished since.",
          bundle: .module)
      default:
        return String(
          localized:
            "\(total) agents kept running while Vibe Manager was closed; \(endedCount) have finished since.",
          bundle: .module,
          comment:
            "Agents left running when the application quit, then how many of them ended since; both above one."
        )
      }
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
          String(localized: "\(lines.count) sessions did not come back.", bundle: .module))
      }
      if cancelledCount > 0 {
        sentences.append(
          String(
            localized: "\(cancelledCount) more were left closed when you cancelled.",
            bundle: .module,
            comment: "Sessions the restoration did not reach, because the user cancelled it."))
      }
      if restartedCount > 0 {
        sentences.append(
          String(localized: "\(restartedCount) sessions came back.", bundle: .module))
      }
      return sentences.joined(separator: " ")
    }
  }

  /// The selection restored from the layout, kept until a load can tell whether it still exists.
  private var preferredSelection: SessionID?
  private var resolutionTask: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?

  public let layout: WorkspaceLayoutController
  /// Every session's web view (#69). Absent in a workspace assembled without it: no web view is
  /// offered, and a link clicked in a terminal opens in the default browser.
  public let browser: BrowserWorkspace?
  let readTicketContext: ReadTicketContext?
  /// The branch and forge each session's ticket was last deduced from.
  var ticketContexts: [SessionID: TicketContext] = [:]
  /// Asks the web view's panel to take the keyboard, or its address bar.
  public internal(set) var webViewFocusRequest = 0
  public internal(set) var addressBarFocusRequest = 0
  /// Whether the web view's address bar holds the keyboard: ⌘W then closes a tab, not the session.
  public var isAddressBarFocused = false
  var webPageFocus = false
  /// Absent in a workspace assembled without the system around it — tests and previews. The
  /// application always has one.
  public let permissions: PermissionsModel?

  let repository: any SessionRepository
  private let loadSessions: LoadSessions
  private let recovery: (any SessionStoreRecovery)?
  let agents: (any AgentProviderResolving)?
  let launcher: SessionLauncher?
  private let defaultWorkingDirectoryPath: String?
  private let closeSession: CloseSession
  private let closePreferences: any SessionClosePreferences
  private let quitPreferences: any QuitPreferences
  private let fileOpeningPreferences: any FileOpeningPreferences
  private let archiveSession: ArchiveSession
  /// Where what happens to the sessions is noted, by pseudonym.
  public let diagnostics: Diagnostics
  private let collectDiagnostics: (@MainActor (AppModel) async -> DiagnosticSnapshot)?
  private let archiveDiagnostics: @Sendable ([DiagnosticFile], Date) -> Data
  /// Bumped to give the keyboard to the session list: Focus Sidebar, ⌥⌘1.
  public private(set) var sidebarFocusRequest = 0
  /// The export under way, from its preview to the file saved.
  public private(set) var diagnosticsExport: DiagnosticsExportModel?
  /// How the previous run ended, as this launch found it: for the export.
  public private(set) var previousShutdownVerdict: DiagnosticToken?
  private let restoreSession: RestoreSession
  private let restartSession: RestartSession?
  private let planAgentSwitch: PlanAgentSwitch?
  private let recordAgentSwitch: RecordAgentSwitch
  private let revertAgentSwitch: RevertAgentSwitch
  private let detectPreviousShutdown: DetectPreviousShutdown?
  private let runtimeRecorder: SessionRuntimeRecorder?
  private let restoreSessions: RestoreSessions?
  private let clock: any SessionClock
  private let readBranchReport: ReadSessionBranchReport?
  private let repositoryStatus: RepositoryStatusMonitor?
  private let importLegacyNotes: ImportLegacyNotes

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
    /// The terminal host that may have kept agents running while the application was closed.
    terminalHost: (any TerminalHosting)? = nil,
    processes: any ProcessLivenessProbe = SystemProcessLivenessProbe(),
    // Only the resume probation reads it, and it is the one rule here measured in seconds of real
    // time: without a clock to move, its far side could only be tested by waiting eight seconds.
    clock: any SessionClock = SystemSessionClock(),
    /// Reads what the agent did to the branches. Absent in a workspace assembled without Git,
    /// where the inspector shows no report at all.
    branchReader: ReadSessionBranchReport? = nil,
    /// Keeps the repositories of the session on screen read, when the disk says they moved.
    /// Absent in a workspace assembled without Git: the report is then read on demand only.
    repositoryStatus: RepositoryStatusMonitor? = nil,
    closePreferences: any SessionClosePreferences = InMemorySessionClosePreferences(),
    fileOpeningPreferences: any FileOpeningPreferences = InMemoryFileOpeningPreferences(),
    /// Where the notes are kept. A workspace assembled without one keeps none.
    notesStore: any SessionNotesStore = NoSessionNotes(),
    /// Where a session's notes file is, for Reveal in Finder when it cannot be read.
    notesFileLocation: (@Sendable (SessionID) -> URL)? = nil,
    quitPreferences: any QuitPreferences = InMemoryQuitPreferences(),
    /// Where the prompt templates are kept. A workspace assembled without one keeps them in
    /// memory for the run.
    templateRepository: any PromptTemplateRepository = InMemoryPromptTemplateRepository(),
    /// The file format templates are exported to and imported from, when there is one.
    templateExchange: (any PromptTemplateExchangeFormat)? = nil,
    /// Where runs are recorded and tokens read. A workspace assembled without it shows no usage.
    usage: UsageModel? = nil,
    /// Follows what each session's agent is doing. Absent in a workspace assembled without it:
    /// running sessions then show as idle.
    activityTracker: TrackAgentActivity? = nil,
    /// What the user decided about the hooks of the CLIs that ask before running them.
    hookConsents: any AgentHookConsentStore = InMemoryAgentHookConsentStore(),
    /// Every session's web view (#69). A workspace assembled without one offers none.
    browser: BrowserWorkspace? = nil,
    /// Reads a session's branch and forge, for the ticket it deduces. Absent without Git.
    ticketContext: ReadTicketContext? = nil,
    /// The diagnostics log. Nothing the user typed ever reaches it: see `DiagnosticEvent`.
    diagnostics: Diagnostics = .disabled,
    /// Gathers what an export holds. Absent, Export Diagnostics is not offered.
    collectDiagnostics: (@MainActor (AppModel) async -> DiagnosticSnapshot)? = nil,
    /// Writes the archive of an export.
    archiveDiagnostics: @escaping @Sendable ([DiagnosticFile], Date) -> Data = { _, _ in Data() },
    /// Keeps each session's journal. Absent, the inspector shows Git alone.
    journal: SessionJournalModel? = nil
  ) {
    self.journal = journal
    journal?.editor = fileOpeningPreferences.editor
    self.activityTracker = activityTracker
    self.hookConsents = hookConsents
    self.browser = browser
    readTicketContext = ticketContext
    self.diagnostics = diagnostics
    self.collectDiagnostics = collectDiagnostics
    self.archiveDiagnostics = archiveDiagnostics
    self.usage = usage
    templates = PromptTemplateLibraryModel(
      repository: templateRepository, exchange: templateExchange, clock: clock)
    notes = NotesModel(
      store: notesStore, fileLocation: notesFileLocation, opener: WorkspaceFileOpener())
    importLegacyNotes = ImportLegacyNotes(repository: repository, notes: notesStore)
    self.closePreferences = closePreferences
    self.quitPreferences = quitPreferences
    quitBehavior = quitPreferences.behavior
    self.fileOpeningPreferences = fileOpeningPreferences
    fileEditor = fileOpeningPreferences.editor
    var listUntracked: GitInspectorModel.ListUntracked?
    if let repositoryStatus {
      listUntracked = { directory, key in
        await repositoryStatus.untrackedFiles(in: directory, of: key)
      }
    }
    gitInspector = GitInspectorModel(
      listUntracked: listUntracked,
      opener: WorkspaceFileOpener(),
      editor: fileOpeningPreferences.editor
    )
    confirmsStoppingRunningAgent = closePreferences.confirmsStoppingRunningAgent
    self.clock = clock
    readBranchReport = branchReader
    self.repositoryStatus = repositoryStatus
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
      RestartSession(repository: repository, agents: $0, notes: notesStore)
    }
    restartSession = restart
    planAgentSwitch = agents.map { PlanAgentSwitch(repository: repository, agents: $0) }
    recordAgentSwitch = RecordAgentSwitch(repository: repository, clock: clock)
    revertAgentSwitch = RevertAgentSwitch(repository: repository)
    // The two halves of #11: what the previous run left behind, and the queue that honours it.
    // Both are absent together, because a workspace that cannot launch has nothing to restore.
    self.runtimeRecorder = runtimeRecorder
    detectPreviousShutdown = runtimeRecorder.map {
      DetectPreviousShutdown(
        repository: repository, recorder: $0, processes: processes, clock: clock,
        host: terminalHost)
    }
    restoreSessions =
      launcher.flatMap { launcher in
        restart.map {
          RestoreSessions(restart: $0, launcher: launcher, repository: repository)
        }
      }

    // A template saved while the sheet is open is said there, never swapped in under the user.
    templates.libraryDidChange = { [weak self] library in
      self?.newSessionModel?.templatesChanged(library.templates)
    }

    usage?.connect { [weak self] in self?.sessions ?? [] }

    launcher?.askHookConsent = { [weak self] name, commands in
      guard let self else { return .undecided }
      return await self.requestHookConsent(agentName: name, commands: commands)
    }

    connectBrowser()

    launcher?.sessionDidClose = { [weak self] id, state in
      guard let self else { return }
      self.noteProcessDidFinish(id, state: state)
      self.noteSwitchedAgentDidFinish(id, state: state)
      // The store already says the session is closed; the list on screen is what has to catch up.
      Task { await self.reload() }
      // An agent that stops has often just committed: its repositories are read once more.
      if id == self.observedSessionID {
        Task { await self.refreshBranchReport() }
      }
    }

    if let repositoryStatus {
      let updates = repositoryStatus.updates
      statusUpdates = Task { [weak self] in
        for await update in updates {
          guard let self else { return }
          self.apply(update)
        }
      }
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
    let filter = filter
    // A session being closed still reads as active until the stop is done. It is already gone
    // as far as the user is concerned.
    let sessions = self.sessions.filter {
      !($0.status == .active && dismissedSessionIDs.contains($0.id))
    }
    // The notes are only read when there is something to look for in them: read every time, each
    // keystroke typed in the notes would redraw the sidebar.
    guard !filter.trimmedSearchText.isEmpty else { return filter.apply(to: sessions) }
    return filter.apply(to: sessions, notes: notes.searchIndex)
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
    guard !closingSessionIDs.contains(session.id) else { return false }
    return session.status == .active || launcher?.isRunning(session.id) == true
  }

  /// Whether closing this session would interrupt an agent at work, and the user wants to be
  /// asked about that. A session whose agent has already stopped loses nothing by closing.
  public func needsCloseConfirmation(_ session: WorkSession) -> Bool {
    confirmsStoppingRunningAgent && launcher?.isRunning(session.id) == true
  }

  /// What ⌘W and every other Close Session run: closes at once, or asks first when an agent
  /// would be interrupted. Does nothing for a session there is nothing left to close.
  public func requestClose(_ id: SessionID) async {
    guard let session = sessions.first(where: { $0.id == id }), canClose(session) else { return }
    guard !needsCloseConfirmation(session) else {
      pendingClose = session
      return
    }
    await close(id)
  }

  public func cancelClose() {
    pendingClose = nil
  }

  /// Closes the session the confirmation was opened for. Takes the identifier for the same reason
  /// `archive(_:)` does: the dialog is dismissed, and `pendingClose` cleared, before this runs.
  public func confirmClose(_ id: SessionID, askAgain: Bool = true) async {
    pendingClose = nil
    if !askAgain {
      confirmsStoppingRunningAgent = false
    }
    await close(id)
  }

  public func canArchive(_ session: WorkSession) -> Bool {
    session.status != .archived
  }

  public func canRestore(_ session: WorkSession) -> Bool {
    session.status == .archived
  }

  /// Stops the agent and keeps everything else, the terminal included.
  ///
  /// The session leaves the list at once and the selection moves to the row that takes its
  /// place — the one below, or the one above at the end of the list. Stopping the agent can take
  /// a while, and the user closed the session to get on with the next one, not to watch a shell
  /// being killed. It is reported only if it goes wrong.
  public func close(_ id: SessionID) async {
    guard !closingSessionIDs.contains(id) else { return }
    closingSessionIDs.insert(id)
    defer { closingSessionIDs.remove(id) }
    dismiss(id)
    diagnostics.record(
      .lifecycle, .info, "session.closeRequested", ["session": diagnostics.pseudonym(id)])
    do {
      let closure = try await closeSession(id: id)
      report(closure.detachment, for: closure.session, action: .closed)
      // Closing a session is reading it.
      await activityTracker?.forget(id)
    } catch {
      await report(error)
    }
    // Still on it only if the user was not looking at its row: listed whatever its state, or
    // hidden by a search. The sidebar then follows it rather than dropping it.
    let isStillSelected = selectedSessionID == id
    await reload()
    // Only once the reload has the session closed: dropped earlier, it would flash back in.
    dismissedSessionIDs.remove(id)
    if isStillSelected {
      follow(id)
    } else {
      // A close that failed leaves the session active, and back in the list: the selection is
      // left where the user is now rather than pulled back to it.
      reconcileSelection()
    }
  }

  /// Takes a session off the list, and moves the selection off it if its row was there and has
  /// gone. A session that is not active stays listed, and one hidden by a search was not where the
  /// user was looking: either way the selection stays on it.
  private func dismiss(_ id: SessionID) {
    let visible = visibleSessions
    let index = visible.firstIndex { $0.id == id }
    dismissedSessionIDs.insert(id)
    guard selectedSessionID == id, let index,
      !visibleSessions.contains(where: { $0.id == id })
    else { return }
    let neighbour =
      visible.indices.contains(index + 1)
      ? visible[index + 1] : (index > 0 ? visible[index - 1] : nil)
    select(neighbour?.id)
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
      await activityTracker?.forget(id)
      browser?.release(id)
      diagnostics.record(
        .session, .info, "session.archived", ["session": diagnostics.pseudonym(id)])
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
      diagnostics.record(
        .session, .info, "session.unarchived", ["session": diagnostics.pseudonym(id)])
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
    guard pendingSwitch?.sessionID != session.id else { return false }
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
      return session.hasEverStarted
        ? String(
          localized: "Restart Session, resuming its \(descriptor.displayName) conversation",
          bundle: .module, comment: "Said by VoiceOver for the Restart action: an agent's name.")
        : String(
          localized: "Start Session, resuming its \(descriptor.displayName) conversation",
          bundle: .module, comment: "Said by VoiceOver for the Start action: an agent's name.")
    }
    return session.hasEverStarted
      ? String(
        localized: "Restart Session in a new process, with a summary", bundle: .module,
        comment: "Said by VoiceOver for the Restart action.")
      : String(
        localized: "Start Session in a new process, with a summary", bundle: .module,
        comment: "Said by VoiceOver for the Start action.")
  }

  /// Stands for the name of a session that is no longer listed.
  private static var unnamedSession: String {
    String(
      localized: "This session", bundle: .module,
      comment: "Stands for the name of a session that is no longer listed.")
  }

  /// A session that was created and never ran is started, not restarted. Promising a restart
  /// there would be a false sentence on the very first use.
  public func restartTitle(for session: WorkSession) -> String {
    session.hasEverStarted
      ? String(
        localized: "Restart Session", bundle: .module,
        comment: "A command of the Session menu, for a session that has run before.")
      : String(
        localized: "Start Session", bundle: .module,
        comment: "A command of the Session menu, for a session that has never run.")
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
    // The summary is written from the notes on disk: what was just typed has to be there first.
    // When it cannot be written, the summary takes what the editor holds rather than an older
    // copy the user can no longer see — and the sheet then judges the same text it shows.
    let notesOverride: String? =
      await notes.flush(id) ? nil : (notes.text(for: id) ?? "")
    // Restarting is an answer to the offer too: the session goes back to work on the agent it has.
    switchBackOffers[id] = nil
    do {
      let restart = try await restartSession(
        id: id,
        contextOverride: contextOverride,
        // A conversation this agent already dropped is not handed back. The user is told so in
        // the summary they are about to read, which is where the news belongs: at the moment
        // they ask for the session again, not as a banner over the one they just closed.
        skippingResume: skippingResume ?? (resumeRefusals.contains(id) ? .failedLastTime : nil),
        notesOverride: notesOverride
      )
      guard !restart.needsConfirmation || confirmed else {
        pendingRestart = PendingRestart(
          sessionID: id,
          sessionName: restart.session.name,
          explanation: restart.explanation?.sentence ?? "",
          briefText: restart.mode.brief?.text ?? "",
          isTruncated: restart.mode.brief?.isTruncated ?? false,
          carriesContext: restart.mode.brief != nil,
          leftOutNotes: NotesInSummary.leftOut(
            notes: notes.text(for: id), brief: restart.mode.brief)
        )
        return
      }

      if case .native = restart.mode {
        resumeAttempts[id] = clock.now()
      } else {
        resumeAttempts[id] = nil
      }

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
          message: reason ?? failure?.message
            ?? String(localized: "This session could not be restarted.", bundle: .module),
          suggestion: reason == nil ? failure?.suggestion : nil,
          sessionID: id
        )
      }
    } catch let refusal as SessionRestartRefusal {
      restartFailure = RestartFailure(
        sessionName: sessions.first { $0.id == id }?.name ?? Self.unnamedSession,
        message: refusal.errorDescription
          ?? String(localized: "This session could not be restarted.", bundle: .module),
        suggestion: refusal.recoverySuggestion,
        sessionID: id
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

  // MARK: - Switching agent

  /// Whether Switch Agent is offered for this session.
  ///
  /// A running session can be switched — the sheet says its agent will be stopped — and so can a
  /// closed one whose agent is not installed any more: that is precisely when another is wanted.
  /// Not an archived one, and not one whose restart, close or switch is already on its way.
  public func canSwitchAgent(_ session: WorkSession) -> Bool {
    guard planAgentSwitch != nil, launcher != nil, session.agent != nil else { return false }
    guard session.status != .archived else { return false }
    // A restoration walks its queue with plans built from the stored agent: switching a session
    // under it would record one agent while the queue starts the other.
    guard restoration == nil else { return false }
    guard !restartingSessionIDs.contains(session.id), !closingSessionIDs.contains(session.id)
    else { return false }
    return pendingRestart?.sessionID != session.id && pendingSwitch?.sessionID != session.id
  }

  /// Opens the Switch Agent sheet. `preselected` is the agent to offer first: the one a quick
  /// failure is offering back.
  public func beginAgentSwitch(_ id: SessionID, preselected: AgentTarget? = nil) {
    guard let agents, let planAgentSwitch,
      let session = sessions.first(where: { $0.id == id }), canSwitchAgent(session)
    else { return }
    let sheet = AgentSwitchModel(
      session: session,
      stopsRunningAgent: launcher?.isRunning(id) == true,
      resumeFailedBefore: resumeRefusals.contains(id),
      registry: agents,
      planner: planAgentSwitch,
      preselected: preselected,
      context: { [weak self] session, names in
        self?.briefInput(for: session, names: names) ?? SessionBriefInput(session: session)
      }
    )
    pendingSwitch = sheet
    Task { await sheet.load() }
    // A session not on screen has no report yet. It is read once, in the background: the sheet
    // opens on what the session recorded, and the summary catches up — unless the user has
    // started editing it, which is theirs to keep.
    if branchReports[id] == nil, let readBranchReport {
      Task { [weak self] in
        let report = await readBranchReport(for: session)
        guard let self else { return }
        if self.branchReports[id] == nil { self.branchReports[id] = report }
        if self.pendingSwitch === sheet { sheet.contextChanged() }
      }
    }
  }

  public func cancelAgentSwitch() {
    pendingSwitch = nil
  }

  public func dismissSwitchFailure() {
    switchFailure = nil
  }

  /// Offers the agent a quick failure left behind, in the sheet, for the user to confirm.
  public func switchBack(_ id: SessionID) {
    guard let offer = switchBackOffers[id] else { return }
    beginAgentSwitch(id, preselected: offer.target)
  }

  /// Runs the switch the sheet describes, with the summary as the user left it.
  public func confirmAgentSwitch() async {
    guard let sheet = pendingSwitch, sheet.canSwitch else { return }
    pendingSwitch = nil
    let summary: String? = sheet.handover == .summary ? sheet.summaryText : nil
    await performAgentSwitch(
      id: sheet.sessionID,
      to: sheet.target,
      previous: sheet.currentLabel,
      summary: summary,
      wasEdited: sheet.isSummaryEdited,
      skippingResume: sheet.skipsResume,
      expecting: sheet.expectedModeKind,
      names: sheet.agentNames
    )
  }

  /// Plan, stop, re-read, record, launch — in that order, so that everything that can refuse
  /// refuses while the current agent still runs, and a launch that fails can put the session back
  /// exactly as it was.
  private func performAgentSwitch(
    id: SessionID,
    to target: AgentTarget,
    previous: String,
    summary: String?,
    wasEdited: Bool,
    skippingResume: Bool,
    expecting: AgentSwitchMode.Kind?,
    names: [String: String]
  ) async {
    guard let launcher, let planAgentSwitch, restoration == nil else { return }
    // The restart lock: a switch and a restart of one session must never cross.
    guard restartingSessionIDs.insert(id).inserted else { return }
    defer { restartingSessionIDs.remove(id) }
    switchFailure = nil
    switchBackOffers[id] = nil
    let name = sessions.first { $0.id == id }?.name ?? Self.unnamedSession

    do {
      // 1. Everything that can refuse, while the agent still runs.
      let current = sessions.first { $0.id == id }
      let plan = try await planAgentSwitch(
        id: id,
        to: target,
        context: current.map { briefInput(for: $0, names: names) },
        summaryOverride: summary,
        skippingResume: skippingResume,
        expecting: expecting
      )

      // 2. The running agent is stopped, and the session closed, before anything is written.
      if launcher.isRunning(id) || plan.session.status == .active {
        closingSessionIDs.insert(id)
        defer { closingSessionIDs.remove(id) }
        let closure = try await closeSession(id: id)
        if case .unreachable(let pid) = closure.detachment {
          throw AgentSwitchRefusal.stopUnconfirmed(processIdentifier: pid)
        }
      }

      // 3 and 4. Recorded on a fresh read of the store; an archive that landed during the stop
      // is refused there.
      let change = try await recordAgentSwitch(plan, wasEdited: wasEdited)
      guard let switched = try await repository.session(id: id) else {
        throw AgentSwitchRefusal.sessionMissing
      }

      // 5. The new agent, in the same pane, under a separator naming both. The attempts are
      // recorded before the launch: a CLI that refuses at once can exit — and its close be
      // reported — while the launch is still wiring the pane up.
      if plan.mode.keepsConversation {
        resumeAttempts[id] = clock.now()
      } else {
        resumeAttempts[id] = nil
        // This process starts a conversation of its own: a refusal of the previous one is moot.
        resumeRefusals.remove(id)
      }
      let back = SwitchBack(
        target: AgentTarget(
          providerID: change.previous.providerID, modelID: change.previous.modelID),
        label: previous
      )
      switchAttempts[id] = (clock.now(), back)

      diagnostics.record(
        .session, .info, "session.agentSwitched",
        [
          "session": diagnostics.pseudonym(id),
          "from": .token(AgentProviderID(change.previous.providerID).diagnosticToken),
          "to": .token(plan.plan.providerID.diagnosticToken),
        ])
      let outcome = await launcher.launchSwitch(plan, session: switched, previous: previous)
      if outcome != .started {
        resumeAttempts[id] = nil
        switchAttempts[id] = nil
        // `alreadyRunning` is a failure here: something else started this session between the
        // stop and the launch, and it is not the agent the store now names.
        let why: String
        switch outcome {
        case .failed(let reason?):
          why = reason
        case .alreadyRunning:
          why = String(
            localized: "Another launch started this session in the meantime.", bundle: .module)
        default:
          why =
            launcher.failure(for: id)?.message
            ?? String(
              localized: "\(plan.targetName) could not be started.", bundle: .module,
              comment: "An agent's name.")
        }
        await undoSwitch(
          id: id, change: change, reason: why, target: plan.targetName, previous: previous,
          name: name)
      }
    } catch let refusal as AgentSwitchRefusal {
      switchFailure = RestartFailure(
        sessionName: name,
        message: refusal.errorDescription
          ?? String(localized: "The agent could not be switched.", bundle: .module),
        suggestion: refusal.recoverySuggestion,
        sessionID: id
      )
    } catch {
      await report(error)
    }
    await reload()
    follow(id)
  }

  /// Puts the session back on the agent the switch left, and says what actually happened: back
  /// on it, or — when even that write was refused — still on the new one, which Restart then
  /// starts with a summary.
  private func undoSwitch(
    id: SessionID,
    change: AgentChange,
    reason: String,
    target: String,
    previous: String,
    name: String
  ) async {
    let suggestion: String
    do {
      try await revertAgentSwitch(id: id, change: change.id, reason: reason)
      suggestion = String(
        localized: "The session is back on \(previous).", bundle: .module,
        comment: "An agent's name.")
    } catch {
      suggestion = String(
        localized: """
          The session could not be put back on \(previous): it stays on \(target), and Restart \
          will start it with a summary.
          """,
        bundle: .module,
        comment: "The agent the switch left, then the one it switched to. Restart is a command.")
    }
    switchFailure = RestartFailure(
      sessionName: name,
      message: String(
        localized: "Could not switch to \(target): \(reason)", bundle: .module,
        comment: "An agent's name, then why it could not be started."),
      suggestion: suggestion,
      sessionID: id
    )
  }

  /// What the summary is built from: the branch report and the Git states this window holds for
  /// the session. The sheet never waits on Git: a session never looked at is summarised from what
  /// it recorded until its report, read in the background, arrives.
  private func briefInput(for session: WorkSession, names: [String: String]) -> SessionBriefInput {
    SessionBriefInput(
      session: session,
      branches: branchReports[session.id],
      statuses: repositoryStatuses.values.filter { $0.key.sessionID == session.id },
      agentNames: names,
      notes: notes.text(for: session.id)
    )
  }

  /// A switched agent that stopped within seconds of starting, with nobody having typed into it
  /// and nothing having stopped it on purpose, is offered back: the pane says why it stopped.
  private func noteSwitchedAgentDidFinish(_ id: SessionID, state: TerminalProcessState) {
    guard let attempt = switchAttempts.removeValue(forKey: id) else { return }
    guard clock.now().timeIntervalSince(attempt.date) < Self.resumeProbation else { return }
    if let pane = launcher?.pane(for: id) {
      guard !pane.hasReceivedInput, !pane.wasStoppedOnPurpose else { return }
    }
    if case .exited(0) = state { return }
    guard state.isFinished else { return }
    switchBackOffers[id] = attempt.previous
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

  public func dismissDetachedNotice() {
    detachedNotice = nil
  }

  public func dismissHostUnavailableNotice() {
    hostUnavailableReason = nil
  }

  /// Asks the host again for the agents left running, and takes them back if it answers.
  ///
  /// Nothing was touched when it did not — neither the store nor the runtime document — so this
  /// is the launch sequence's own detection, run once more.
  public func retryHostReattach() async {
    guard hostUnavailableReason != nil, !isRetryingHost else { return }
    isRetryingHost = true
    defer { isRetryingHost = false }
    await runtimeRecorder?.unseal()
    let shutdown = await detectPreviousShutdown?()
    note(shutdown)
    hostUnavailableReason = nil
    await reload()
    await reattach(shutdown)
    // The first attempt sealed the usage too: settled now, before anything is resumed, or the
    // runs of this whole launch would go unrecorded.
    await settleUsage()
    announce(shutdown)
    await resume(shutdown)
  }

  /// Once the host has said which agents it kept: those runs go on, the others ended while away.
  private func settleUsage() async {
    guard let usage else { return }
    let running = Set(sessions.map(\.id).filter { launcher?.isRunning($0) == true })
    // A copy of the application that found another one working here only reads.
    let readOnly = await runtimeRecorder?.isReadOnly() ?? false
    await usage.settleLaunch(running: running, sessions: sessions, readOnly: readOnly)
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
    case .detached(let sessions):
      guard !sessions.running.isEmpty || !sessions.ended.isEmpty else { return }
      let notice = DetachedNotice(
        runningCount: sessions.running.count, endedCount: sessions.ended.count)
      detachedNotice = notice
      // Nothing to act on when everything is simply back: the sentence goes away by itself.
      guard sessions.ended.isEmpty else { return }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(8))
        guard self?.detachedNotice == notice else { return }
        self?.detachedNotice = nil
      }
    case .hostUnavailable(let reason):
      hostUnavailableReason = reason
    case .none, .nothingToDo, .clean:
      return
    }
  }

  /// The verdict on the previous run, with how many sessions it concerns: never which.
  private func note(_ shutdown: PreviousShutdown?) {
    guard let shutdown else { return }
    previousShutdownVerdict = shutdown.diagnosticToken
    var fields: [(name: StaticString, value: DiagnosticValue)] = [
      ("verdict", .token(shutdown.diagnosticToken))
    ]
    switch shutdown {
    case .clean(let intent):
      fields.append(("sessions", .count(intent.sessionIDs.count)))
    case .unexpected(let intent, let leftovers):
      fields.append(("sessions", .count(intent.sessionIDs.count)))
      fields.append(("leftovers", .count(leftovers.count)))
    case .detached(let detached):
      fields.append(("running", .count(detached.running.count)))
      fields.append(("ended", .count(detached.ended.count)))
      fields.append(("sessions", .count(detached.resume.sessionIDs.count)))
    case .nothingToDo, .otherInstance, .hostUnavailable:
      break
    }
    diagnostics.log.record(
      DiagnosticEvent(.lifecycle, .notice, "app.previousShutdown", fields: fields))
  }

  /// Puts back on screen what the terminal host kept: the running agents, and the last output of
  /// the ones that ended while the application was closed. Nothing is started or sent.
  private func reattach(_ shutdown: PreviousShutdown?) async {
    guard case .detached(let detached) = shutdown, let launcher else { return }
    for id in detached.running + detached.ended {
      guard let session = sessions.first(where: { $0.id == id }) else { continue }
      await launcher.adopt(session)
    }
  }

  /// The verdicts that put sessions back to work by themselves.
  private func resume(_ shutdown: PreviousShutdown?) async {
    switch shutdown {
    case .clean(let intent):
      await beginRestore(intent)
    case .detached(let detached):
      await beginRestore(detached.resume)
    default:
      return
    }
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
    let firstList = Signposts.begin("launch.firstList")
    // The stored selection is read before the sessions, so the first list that arrives can be
    // asked whether that session still exists instead of selecting its first row and losing it.
    preferredSelection = await layout.restore()
    // Beside the load rather than before it: the notes only serve the search, and the list must
    // not wait on reading them.
    notes.startPreparing(importing: importLegacyNotes)
    await templates.load()
    // Before the sessions, and never from the creation flow: the point of the whole step is that
    // pressing Create leaves nothing left to ask. Reading the store first left a window in which
    // ⌘N opened a sheet that did not yet know whether the access was there, and warned anyway.
    await permissions?.refresh()
    // Before the first list, because it is what makes that list true: a session the previous run
    // left `active` has nothing running behind it, and drawing it as running once — even for one
    // frame — is the lie this whole ticket is about.
    let shutdown = await detectPreviousShutdown?()
    note(shutdown)
    // Before any process is started or adopted: what the last launch left unread comes back with
    // the first list.
    await startFollowingActivity()
    await journal?.start()
    await reload()
    Signposts.end("launch.firstList", firstList)
    // Which agents write a usage is part of their description, known without probing any of them.
    if let usage, let agents {
      usage.reportingProviderIDs = Set(
        await agents.descriptors().filter(\.capabilities.reportsUsage).map(\.id.rawValue))
    }
    // Before anything is said or probed: these agents are running now, and their panes are how
    // the list shows it.
    await reattach(shutdown)
    await settleUsage()
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
    usage?.reportingProviderIDs = Set(
      descriptors.filter(\.capabilities.reportsUsage).map(\.id.rawValue))
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
    // Leaving a session is when the user considers its notes done: they are written now.
    if let previous = selectedSessionID, previous != id {
      Task { [notes] in await notes.flush(previous) }
    }
    selectedSessionID = id
    layout.select(id)
    watchBranches()
    updateVisibleSession()
    selectionDidChange(to: id)
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

  /// Whether this session's agent runs inside the application — the terminal host could not be
  /// used for it — and so will stop when the application quits, whatever is answered then.
  public func willStopWithApplication(_ id: SessionID) -> Bool {
    launcher?.willStopWithApplication(id) ?? false
  }

  public func launchFailure(for id: SessionID) -> TerminalPaneModel.Failure? {
    launcher?.failure(for: id)
  }

  /// The sheet's model lives here, not in the sheet: SwiftUI may evaluate the presentation
  /// closure more than once, and a draft must survive that without being typed twice.
  /// Opens the New Session sheet, on a template when one is given.
  public func beginNewSession(template: PromptTemplateID? = nil) {
    guard let agents, canCreateSession else { return }
    let model = NewSessionModel(
      create: CreateSession(
        repository: repository, agents: agents, ticketContext: readTicketContext),
      registry: agents,
      fullDiskAccess: permissions?.status,
      templates: templates.all
    )
    if let template {
      model.selectTemplate(template)
    }
    newSessionModel = model
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
    diagnostics.record(
      .session, .info, "session.created",
      [
        "session": diagnostics.pseudonym(creation.session.id),
        "provider": .token(AgentProviderID(creation.plan.providerID.rawValue).diagnosticToken),
      ])
    guard let launcher else { return }
    await launcher.launch(session: creation.session, plan: creation.plan)
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

  public var canExportDiagnostics: Bool { collectDiagnostics != nil }

  /// Opens the export sheet, and gathers what it shows. Nothing is written until the user saves.
  public func beginDiagnosticsExport() {
    guard let collectDiagnostics, diagnosticsExport == nil else { return }
    let export = DiagnosticsExportModel(archive: archiveDiagnostics, diagnostics: diagnostics)
    diagnosticsExport = export
    Task { [weak self] in
      guard let self else { return }
      export.load(await collectDiagnostics(self))
    }
  }

  public func endDiagnosticsExport() {
    diagnosticsExport = nil
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
    let message =
      (error as? LocalizedError)?.errorDescription
      ?? String(localized: "Unable to load work sessions.", bundle: .module)
    let canRestoreBackup = await recovery?.recoveryStatus() == .backupAvailable

    if sessions.isEmpty {
      state = .failed(message: message, canRestoreBackup: canRestoreBackup)
    } else {
      refreshFailure = RefreshFailure(message: message, canRestoreBackup: canRestoreBackup)
    }
  }
}

// MARK: - Branch report

extension AppModel {
  public func branchReport(for id: SessionID) -> SessionBranchReport? {
    branchReports[id]
  }

  public var reportsBranches: Bool { readBranchReport != nil }

  /// Whether the repositories of the session on screen are kept live, rather than read on demand.
  public var observesRepositories: Bool { repositoryStatus != nil }

  public func repositoryStatus(for id: SessionID, path: String) -> RepositoryStatusState? {
    repositoryStatuses[RepositoryStatusKey(sessionID: id, repositoryPath: path)]
  }

  /// Reads the branches of the session on screen, then watches its repositories — and only that
  /// session: reading twenty repositories that nobody is looking at would cost the disk for
  /// nothing. Nothing is read again on a timer: the monitor says when the transcript grew or a
  /// branch moved, and that is when the report is read again.
  func watchBranches() {
    guard readBranchReport != nil, let id = selectedSessionID else {
      observedSessionID = nil
      if let repositoryStatus {
        stopObserving(with: repositoryStatus, unless: nil)
      }
      return
    }
    // A reload re-applies the same selection; a session already watched is left alone.
    guard observedSessionID != id else { return }
    let hadPrevious = observedSessionID != nil
    observedSessionID = id
    // The session left is no longer watched even if the new one's report never comes. A stop that
    // lands after the new session's first `observe` leaves it alone.
    if hadPrevious, let repositoryStatus {
      stopObserving(with: repositoryStatus, unless: id)
    }
    requestBranchReport(of: id)
  }

  /// Each stop waits for the one before it, and `observeRepositories` for the last of them: two
  /// tasks started one after the other may run in any order, and a stop that reached the monitor
  /// after the next `observe` would leave the session on screen unwatched.
  private func stopObserving(with monitor: RepositoryStatusMonitor, unless keep: SessionID?) {
    let previous = pendingStop
    pendingStop = Task {
      await previous?.value
      await monitor.stopObserving(unless: keep)
    }
  }

  /// Reads everything the session on screen shows again: its report and its repositories. The
  /// user asked, or came back to the application, or its agent just stopped.
  public func refreshBranchReport() async {
    guard let id = selectedSessionID else { return }
    await repositoryStatus?.refresh()
    watchBranches()
    // Through the same queue as every other reading: two reports read side by side could land in
    // the wrong order and hand the monitor the older list of repositories last.
    await requestBranchReport(of: id).value
  }

  /// Called when the application comes back to the front: an event may have been missed while
  /// the Mac slept or a volume was away.
  public func applicationDidBecomeActive() {
    isApplicationActive = true
    updateVisibleSession()
    if let id = selectedSessionID { refreshTicket(of: id) }
    if let journal {
      Task { await journal.refresh() }
    }
    guard observedSessionID != nil else { return }
    Task { await refreshBranchReport() }
  }

  /// Called when another application comes to the front: whatever was typed in the notes is
  /// written, as it would be on leaving the session.
  public func applicationWillResignActive() {
    isApplicationActive = false
    updateVisibleSession()
    Task { [notes] in _ = await notes.flushAll() }
  }

  /// Edit Notes: the inspector is shown if it was hidden, and its editor takes the keyboard.
  public func focusNotes() {
    guard selectedSessionID != nil else { return }
    if !layout.columns.isInspectorVisible {
      layout.setInspectorVisible(true)
    }
    notes.requestFocus()
  }

  /// Escape in the notes: the keyboard goes back to the session's terminal.
  public func focusTerminal() {
    guard let id = selectedSessionID else { return }
    launcher?.pane(for: id)?.requestFocus()
  }

  public func focusSidebar() {
    if !layout.columns.isSidebarVisible {
      layout.setSidebarVisible(true)
    }
    sidebarFocusRequest += 1
  }

  /// Focus Inspector, ⌥⌘3: the inspector is shown if it was hidden, and its list takes the
  /// keyboard.
  public func focusInspector() {
    guard selectedSessionID != nil else { return }
    if !layout.columns.isInspectorVisible {
      layout.setInspectorVisible(true)
    }
    if let journal, layout.intent.inspectorTopTab == .activity {
      journal.requestFocus()
    } else {
      gitInspector.requestFocus()
    }
  }

  /// Read Last Output, ⌃⌥⌘O: VoiceOver says the last lines the selected session's terminal
  /// showed. On demand only — never as output arrives.
  public func readLastOutput() async {
    guard let id = selectedSessionID, let session = pane(for: id)?.session else {
      Announcer.announce(LocalizedStringResource("No terminal is selected.", bundle: .module))
      return
    }
    let lines = TerminalText.lastLines(of: await session.history().bytes, count: 5)
    if lines.isEmpty {
      Announcer.announce(
        LocalizedStringResource("The terminal has shown nothing yet.", bundle: .module))
    } else {
      Announcer.announce(lines.joined(separator: "\n"))
    }
  }

  /// Stops every watch, for good. Called on the way out.
  public func stopWatchingRepositories() async {
    statusUpdates?.cancel()
    await repositoryStatus?.stop()
    // Summaries under way are called off; the turns they covered wait for the next launch.
    await journal?.stop()
  }

  func readBranches(of id: SessionID) async {
    guard let readBranchReport, let session = sessions.first(where: { $0.id == id }) else {
      return
    }
    let report = await readBranchReport(for: session)
    guard !Task.isCancelled else { return }
    branchReports[id] = report
  }

  /// One reading of the report at a time, and one more for whatever asked during it — after a
  /// pause that grows with how long the reading took, as the monitor does for `git status`. An
  /// agent streaming its transcript asks for a report many times a second; it gets one every so
  /// often, never more than its repositories can answer.
  @discardableResult
  private func requestBranchReport(of id: SessionID) -> Task<Void, Never> {
    if let reading = reportReadings[id] {
      pendingReports.insert(id)
      return reading
    }
    let task = Task { [weak self] in
      guard let self else { return }
      let clock = ContinuousClock()
      while true {
        self.pendingReports.remove(id)
        let started = clock.now
        await self.readBranches(of: id)
        await self.observeRepositories(of: id)
        guard self.pendingReports.contains(id), self.observedSessionID == id else { break }
        let pause = max(Self.minimumReportPause, (clock.now - started) * 2)
        try? await Task.sleep(for: pause)
      }
      self.reportReadings[id] = nil
    }
    reportReadings[id] = task
    return task
  }

  /// The shortest pause between two readings of the same report asked for by the disk.
  static let minimumReportPause: Duration = .seconds(1)

  /// Hands the repositories of the report to the monitor. Only for the session still on screen: a
  /// reading that ends after the user moved on must not take the watch back.
  private func observeRepositories(of id: SessionID) async {
    await pendingStop?.value
    guard let repositoryStatus, observedSessionID == id,
      let session = sessions.first(where: { $0.id == id }), let report = branchReports[id]
    else { return }
    let repositories = report.repositories.map { repository in
      ObservedRepository(
        path: repository.path, sharedWith: sharers(of: repository.path, besides: id))
    }
    await repositoryStatus.observe(session, repositories: repositories)
  }

  /// The other sessions whose last report names this repository. Only what has been read in this
  /// run is known: a session never shown since launch is not counted.
  private func sharers(of path: String, besides id: SessionID) -> [SessionID] {
    sessions
      .filter { session in
        session.id != id && session.status != .archived
          && branchReports[session.id]?.repositories.contains { $0.path == path } == true
      }
      .map(\.id)
  }

  private func apply(_ update: RepositoryStatusUpdate) {
    switch update {
    case .states(let states):
      for state in states {
        repositoryStatuses[state.key] = state
      }
      gitInspector.statesChanged(states)
    case .branchReportOutdated(let id):
      guard id == observedSessionID else { return }
      requestBranchReport(of: id)
    }
  }
}
