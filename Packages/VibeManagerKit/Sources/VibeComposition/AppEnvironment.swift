import Foundation
import VibeAgents
import VibeApplication
import VibeBrowser
import VibeDomain
import VibeGit
import VibePersistence
import VibeProcess
import VibeTerminal
import VibeTerminalUI
import VibeUI

/// The application, composed: every port wired to what answers it on a Mac.
///
/// A module of its own rather than a file of the application target, so that a test can compose
/// the real application — its file store, its runtime document, its terminal host in a process of
/// its own — against a temporary folder, and drive it as the interface would.
@MainActor
public final class AppEnvironment {
  /// What differs between the application and a test that composes it.
  public struct Configuration {
    public enum HostLaunch {
      /// The application's own binary, unless `VIBE_TERMINAL_HOST=off`.
      case bundled
      /// No host is ever started: every terminal runs in the application.
      case none
      case launcher(any TerminalHostLaunching)
    }

    /// Read for `VIBE_DATA_DIRECTORY`, `VIBE_TERMINAL_HOST` and the agents' own variables.
    public var environment: [String: String]
    public var hostLaunch: HostLaunch
    public var verifier: any TerminalHostPeerVerifier
    /// The agents offered. `nil` is Claude Code and Codex, and the mock when it is enabled.
    public var providers: ((any DiagnosticLog) -> [any AgentProvider])?
    /// The user defaults suite of an isolated copy. `nil` derives it from the environment.
    public var defaultsSuite: String?
    public var fullDiskAccessProbe: any FullDiskAccessProbe
    /// Where the system writes crash reports, read by an export.
    public var crashReports: URL
    /// The program the agents start as their web view's bridge (#69): this application's binary,
    /// given `--browser-bridge`. `nil` gives the agents no web view tools — outside an application
    /// bundle, the test runner would be started instead.
    public var browserBridgeExecutable: String?

    public init(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      hostLaunch: HostLaunch = .bundled,
      verifier: any TerminalHostPeerVerifier = CodeSigningPeerVerifier(),
      providers: ((any DiagnosticLog) -> [any AgentProvider])? = nil,
      defaultsSuite: String? = nil,
      fullDiskAccessProbe: any FullDiskAccessProbe = TCCFullDiskAccessProbe(),
      crashReports: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
      browserBridgeExecutable: String? = AppEnvironment.bundledExecutable()
    ) {
      self.environment = environment
      self.hostLaunch = hostLaunch
      self.verifier = verifier
      self.providers = providers
      self.defaultsSuite = defaultsSuite
      self.fullDiskAccessProbe = fullDiskAccessProbe
      self.crashReports = crashReports
      self.browserBridgeExecutable = browserBridgeExecutable
    }
  }

  public let appModel: AppModel
  /// Held here as well as inside the model: the settings window is a scene of its own, and it
  /// must read the same status the workspace read rather than probe the system a second time.
  public let permissions: PermissionsModel

  /// What this run notes about itself (ADR 0020): `app.jsonl`, and the unified log.
  public let diagnostics: Diagnostics
  public let diagnosticsLocation: DiagnosticsLocation
  private let diagnosticsFile: FileDiagnosticLog
  /// Where this copy keeps what it writes.
  public let dataDirectory: URL
  public let terminalSupervisor: HostedTerminalSupervisor
  public let launcher: SessionLauncher
  private let prepareForQuit: PrepareForQuit
  private let detachForQuit: DetachForQuit
  /// On in Debug and with `DiagnosticsVerbose`: a timer that asks the main thread ten times a
  /// second is not free, and a release build has Instruments for that.
  private let hangDetector: MainThreadHangDetector?
  private let memorySampler: MemorySampler
  private let activityTracker: TrackAgentActivity
  /// Every session's web view, and the socket its agents reach it through (#69).
  public let browser: BrowserWorkspace
  private let browserChannel: BrowserChannelListener

  public init(configuration: Configuration = Configuration()) {
    let data = Self.dataLocation(
      environment: configuration.environment,
      defaultsSuite: configuration.defaultsSuite
        ?? configuration.environment["VIBE_DEFAULTS_SUITE"].flatMap { $0.isEmpty ? nil : $0 })
    dataDirectory = data.store.deletingLastPathComponent()
    // A folder made by an early build or restored from a backup keeps whatever mode it had; the
    // application's own are brought back to owner only before anything is read from them.
    let repaired = DataDirectoryPermissions.repair([
      data.store.deletingLastPathComponent(), data.notes, data.journal, data.usage, data.logs,
      data.icons,
    ])
    let diagnosticsLocation = DiagnosticsLocation(directory: data.logs)
    self.diagnosticsLocation = diagnosticsLocation
    let (diagnostics, diagnosticsFile) = Diagnostics.standard(
      location: diagnosticsLocation, origin: .app)
    self.diagnostics = diagnostics
    self.diagnosticsFile = diagnosticsFile
    diagnostics.log.record(
      DiagnosticEvent(
        .lifecycle, .notice, "app.launched",
        fields: ApplicationFacts.current().launchFields + [
          ("isolatedData", .flag(data.defaultsSuite != nil))
        ]))
    if !repaired.isEmpty {
      diagnostics.record(
        .store, .notice, "store.permissionsRepaired", ["count": .count(repaired.count)])
    }
    let repository = FileSessionRepository(storeURL: data.store, diagnostics: diagnostics.log)
    let notes = FileSessionNotesStore(directory: data.notes, diagnostics: diagnostics)
    let providers =
      configuration.providers?(diagnostics.log)
      ?? Self.providers(environment: configuration.environment, diagnostics: diagnostics.log)
    let registry = AgentProviderRegistry(providers: providers)
    // Every terminal runs in the terminal host, so its agent can be left running when the
    // application quits (ADR 0017). One host per data directory: an isolated copy has its own.
    let supervisor = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: TerminalHostLocation(dataDirectory: data.store.deletingLastPathComponent()),
        launcher: Self.hostLauncher(
          configuration.hostLaunch, logDirectory: data.logs,
          environment: configuration.environment),
        verifier: configuration.verifier,
        diagnostics: diagnostics
      )
    )

    terminalSupervisor = supervisor
    // The runtime document: what this copy of the application is running, so the next launch can
    // tell a quit from a crash and knows what to put back to work. Deliberately a document of its
    // own, next to the session store and never inside it.
    #if DEBUG
      hangDetector = MainThreadHangDetector(log: diagnostics.log)
    #else
      hangDetector =
        DiagnosticsVerbosity.minimumLevel() == .debug
        ? MainThreadHangDetector(log: diagnostics.log) : nil
    #endif
    hangDetector?.start()
    let runtimeStore = FileSessionRuntimeStateStore(url: data.runtime)
    let recorder = SessionRuntimeRecorder(store: runtimeStore)
    let usageLedger = FileUsageLedger(directory: data.usage)
    let usageTracking = FileUsageTrackingStore(directory: data.usage)
    let usageRecorder = UsageRecorder(ledger: usageLedger, tracking: usageTracking)
    let usage = UsageService(
      recorder: usageRecorder,
      ledger: usageLedger,
      tracking: usageTracking,
      tokenStore: FileTokenUsageStore(directory: data.usage),
      reader: AgentUsageReader()
    )
    // What each agent is doing (#45): its hooks append to a log per session, beside the store.
    let dataFolder = data.store.deletingLastPathComponent()
    let activityTracker = TrackAgentActivity(
      logs: FileAgentActivityLog(
        directory: dataFolder.appendingPathComponent("AgentActivity", isDirectory: true)),
      store: FileAgentActivityStateStore(
        url: dataFolder.appendingPathComponent("agent-activity.json", isDirectory: false))
    )
    self.activityTracker = activityTracker
    let hookConsents = UserDefaultsAgentHookConsentStore(suiteName: data.defaultsSuite)
    // The web view (#69): its tabs and trace beside the store, its choices in the user defaults,
    // its cookies in a website data store of this copy's own.
    let hostLocation = TerminalHostLocation(dataDirectory: dataFolder)
    let browserSettings = UserDefaultsBrowserSettings(suiteName: data.defaultsSuite)
    let browserStore = FileBrowserStore(
      directory: dataFolder.appendingPathComponent("Browser", isDirectory: true))
    let browser = BrowserWorkspace(
      stateStore: browserStore, logStore: browserStore, permissions: browserSettings,
      preferences: browserSettings,
      configuration: BrowserWebConfiguration(
        storeIdentifierFile: dataFolder.appendingPathComponent("browser-store-identifier")))
    self.browser = browser
    let commandDirectory = Self.installCommand(
      at: hostLocation, executable: configuration.browserBridgeExecutable)
    let bridge = configuration.browserBridgeExecutable
    let socketPath = hostLocation.browserSocketPath
    let provideTools = ProvideAgentTools(agents: registry) { [browserSettings] in
      guard browserSettings.givesAgentsWebView, let bridge else { return nil }
      return ProvideAgentTools.Setup(
        servers: [
          AgentToolServer(
            name: BrowserToolCatalog.serverName, executablePath: bridge,
            arguments: [BrowserBridge.bridgeFlag, socketPath])
        ],
        pathPrefix: commandDirectory?.path,
        environment: [BrowserBridge.socketEnvironmentKey: socketPath].merging(
          commandDirectory.map {
            ["BROWSER": $0.appendingPathComponent("open", isDirectory: false).path]
          } ?? [:]
        ) { $1 })
    }
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry,
      recorder: recorder,
      usage: usageRecorder,
      activity: activityTracker,
      reportActivity: ReportAgentActivity(
        agents: registry, tracker: activityTracker, consents: hookConsents,
        diagnostics: diagnostics),
      provideTools: provideTools,
      diagnostics: diagnostics
    )
    self.launcher = launcher
    // Each agent is identified by its number and by when it started, read as soon as the launcher
    // knows it: a number read again at connection time could already belong to another process.
    let agentProcesses = AgentProcessRegistry()
    launcher.processDidStart = { id, pid in agentProcesses.record(id, pid) }
    browserChannel = BrowserChannelListener(
      socketPath: socketPath, prepare: { try hostLocation.prepare() }, runner: browser,
      sessions: { [weak launcher, browserSettings] in
        // Agents not given the web view are not let in by another door either.
        guard browserSettings.givesAgentsWebView, let launcher else { return [] }
        return await launcher.runningProcessIdentifiers().compactMap { id, pid in
          agentProcesses.process(id, pid)
        }
      })
    do {
      try browserChannel.start()
    } catch {
      diagnostics.record(.lifecycle, .error, "browser.channelUnavailable")
    }
    memorySampler = MemorySampler(
      diagnostics: diagnostics, launcher: launcher, supervisor: supervisor)
    memorySampler.start()
    prepareForQuit = PrepareForQuit(
      repository: repository,
      runtime: launcher,
      recorder: recorder
    )
    detachForQuit = DetachForQuit(
      repository: repository,
      runtime: launcher,
      handOff: launcher,
      host: supervisor,
      recorder: recorder
    )
    // The only permission the application ever asks for, wired to the system that answers it:
    // the TCC witness for the status, the user defaults for the answer already given.
    let permissions = PermissionsModel(
      gate: FullDiskAccessGate(
        probe: configuration.fullDiskAccessProbe,
        // An isolated copy keeps its answer apart, like its other preferences.
        preferences: UserDefaultsPermissionPreferences(suiteName: data.defaultsSuite)
      )
    )
    self.permissions = permissions
    let transcripts = AgentTranscriptReader()
    // Each session's journal (#36): read from the transcripts of every active session, summarized
    // by its own agent, kept in a file per session beside the notes.
    let journalPreferences = UserDefaultsJournalPreferences(suiteName: data.defaultsSuite)
    let journal = SessionJournalModel(
      monitor: SessionJournalMonitor(
        store: FileSessionJournalStore(directory: data.journal),
        reader: SessionJournalReader(),
        repositories: GitRepositoryIdentityResolver(
          git: ProcessGitCommandRunner(timeout: .seconds(10), diagnostics: diagnostics.log)),
        summarizers: AgentSessionSummarizers(agents: registry),
        events: FSEventsFileChangeObserver(),
        repository: repository,
        summariesEnabled: journalPreferences.summariesEnabled),
      preferences: journalPreferences)
    appModel = AppModel(
      repository: repository,
      recovery: repository,
      agents: registry,
      launcher: launcher,
      // No folder is proposed. The home directory used to be, and it is the one place that
      // contains Desktop, Documents and Downloads without being guarded itself: accepting the
      // default let an agent walk straight into them, with nothing said beforehand. Choosing is
      // now always a gesture, and the open panel is what grants the access along the way.
      defaultWorkingDirectoryPath: nil,
      layout: WorkspaceLayoutController(
        store: UserDefaultsWorkspaceLayoutStore(suiteName: data.defaultsSuite)),
      permissions: permissions,
      runtimeRecorder: recorder,
      terminalHost: supervisor,
      // Read only: the application reports the branches and worktrees the agent made, and never
      // makes one itself.
      branchReader: ReadSessionBranchReport(
        reader: GitActivityReader(git: ProcessGitCommandRunner(diagnostics: diagnostics.log)),
        transcripts: transcripts),
      // Read only as well, and only when the disk says something moved: no timer reads a
      // repository. One transcript reader for both, so each file is read once, incrementally.
      repositoryStatus: RepositoryStatusMonitor(
        reader: GitStatusReader(
          git: ProcessGitCommandRunner(timeout: .seconds(30), diagnostics: diagnostics.log)),
        events: FSEventsFileChangeObserver(),
        transcripts: transcripts
      ),
      closePreferences: UserDefaultsSessionClosePreferences(suiteName: data.defaultsSuite),
      fileOpeningPreferences: UserDefaultsFileOpeningPreferences(suiteName: data.defaultsSuite),
      notesStore: notes,
      notesFileLocation: { notes.fileURL(for: $0) },
      quitPreferences: UserDefaultsQuitPreferences(suiteName: data.defaultsSuite),
      templateRepository: FilePromptTemplateRepository(storeURL: data.templates),
      templateExchange: PromptTemplateExchangeCodec(),
      usage: UsageModel(service: usage),
      activityTracker: activityTracker,
      hookConsents: hookConsents,
      browser: browser,
      ticketContext: ReadTicketContext(
        git: ProcessGitCommandRunner(timeout: .seconds(10), diagnostics: diagnostics.log)),
      diagnostics: diagnostics,
      collectDiagnostics: { model in
        await Self.snapshot(
          of: model,
          context: SnapshotContext(
            data: data, location: diagnosticsLocation, file: diagnosticsFile,
            runtime: runtimeStore, supervisor: supervisor, launcher: launcher,
            hostEnabled: Self.hostLauncher(
              configuration.hostLaunch, logDirectory: data.logs,
              environment: configuration.environment) != nil,
            crashReports: configuration.crashReports))
      },
      archiveDiagnostics: { files, date in ZipArchiveWriter.archive(files, at: date) },
      journal: journal,
      folderLabels: FileFolderLabelStore(url: data.folders),
      projectIcons: FileSystemProjectIconFinder(),
      iconStore: FileSessionIconStore(directory: data.icons)
    )
  }

  /// Everything the export gathers besides the model.
  private struct SnapshotContext {
    let data: DataLocation
    let location: DiagnosticsLocation
    let file: FileDiagnosticLog
    let runtime: FileSessionRuntimeStateStore
    let supervisor: HostedTerminalSupervisor
    let launcher: SessionLauncher
    let hostEnabled: Bool
    let crashReports: URL
  }

  /// What an export holds, gathered now. No agent is probed: its last detection is what the
  /// workspace already shows.
  private static func snapshot(
    of model: AppModel, context: SnapshotContext
  ) async -> DiagnosticSnapshot {
    context.file.flush()
    let facts = ApplicationFacts.current()
    let runtime = await context.runtime.read()
    let editor: DiagnosticToken
    switch model.fileEditor {
    case nil: editor = "unset"
    case .defaultApplication: editor = "defaultApplication"
    case .application: editor = "application"
    }
    return DiagnosticSnapshot(
      createdAt: Date(),
      application: DiagnosticSnapshot.Application(
        version: DiagnosticVersion(facts.version), build: DiagnosticVersion(facts.build),
        operatingSystem: DiagnosticVersion(facts.operatingSystem),
        architecture: facts.architecture == "arm64" ? "arm64" : "x86_64",
        signature: facts.signature.diagnosticToken,
        teamIdentifier: facts.teamIdentifier.flatMap(DiagnosticVersion.init),
        hardenedRuntime: facts.hardenedRuntime),
      settings: DiagnosticSnapshot.Settings(
        quitBehavior: model.quitBehavior.diagnosticToken,
        confirmsStoppingRunningAgent: model.confirmsStoppingRunningAgent,
        fileEditor: editor,
        verboseDiagnostics: DiagnosticsVerbosity.minimumLevel() == .debug,
        isolatedData: context.data.defaultsSuite != nil,
        terminalHost: context.hostEnabled),
      agents: model.agentDiagnostics.map(DiagnosticSnapshot.Agent.init),
      store: DiagnosticsCollector.store(
        storeURL: context.data.store, notesDirectory: context.data.notes,
        statuses: model.sessions.map(\.status)),
      runtime: DiagnosticSnapshot.Runtime(
        phase: runtime?.phase.diagnosticToken,
        updatedAt: runtime?.updatedAt,
        recordedSessions: runtime?.sessions.count ?? 0,
        previousShutdown: model.previousShutdownVerdict,
        host: await context.supervisor.diagnosticReport(),
        sessionsRunningInApplication: context.launcher.inProcessRunningCount),
      logs: DiagnosticsCollector.logs(in: context.location),
      crashReports: DiagnosticsCollector.crashReports(in: context.crashReports))
  }

  /// Sessions whose agent could be left running when the application quits.
  public var hostedRunningCount: Int {
    launcher.hostedRunningCount
  }

  /// Sessions whose agent runs inside the application, and will stop with it regardless.
  public var inProcessRunningCount: Int {
    launcher.inProcessRunningCount
  }

  /// Everything quitting owes the next launch, in the order it is owed.
  ///
  /// The sessions are stopped and closed **before** the intention to resume them is written, so
  /// that intention can only name sessions that really stopped. The two `stopAll` calls behind it
  /// are the safety net: a terminal the launcher never knew about, or a session the store could
  /// not be asked about, still has its process taken down.
  ///
  /// Leaving the agents running replaces the stops with a hand-off: nothing is stopped that the
  /// terminal host can keep, and the store keeps calling those sessions active, because they are.
  public func shutdown(keepingAgentsRunning: Bool) async {
    diagnostics.record(
      .lifecycle, .notice, "app.quit",
      [
        "route": .token(keepingAgentsRunning ? "keepRunning" : "stopAll"),
        "hosted": .count(hostedRunningCount), "inProcess": .count(inProcessRunningCount),
      ])
    memorySampler.stop()
    hangDetector?.stop()
    // The pending layout is written first: quitting is exactly when the delayed save that keeps
    // a separator drag cheap would otherwise be thrown away.
    await appModel.layout.flush()
    // No FSEvents stream and no new `git status` outlive the window they were reading for.
    await appModel.stopWatchingRepositories()
    // A restoration under way is called off *and waited for*: cancelling only asks, and a resume
    // already in flight would otherwise write `reopen` after this shutdown had decided what to
    // close.
    // A launch waiting on the consent sheet is answered — no answer — so the restoration it
    // belongs to can be called off and waited for.
    appModel.answerHookConsent(.undecided)
    await appModel.stopRestoring()
    // What is unread, and how far each log was read, for the next launch.
    await activityTracker.flush()
    // The tabs and the trace of every web view, and no more connections: an agent's bridge that
    // calls now is told the application is closed.
    await browser.flush()
    browserChannel.stop()
    if keepingAgentsRunning {
      await detachForQuit()
      // The lines of this very path are the ones worth reading if the agents are not found again.
      diagnostics.flush()
      return
    }
    await prepareForQuit()
    await launcher.stopAll()
    await terminalSupervisor.stopAll(gracePeriod: .seconds(3))
    // Said rather than left to the host to infer: a client that simply vanished reads as a crash.
    await terminalSupervisor.relinquish(keepRunning: false)
    diagnostics.flush()
  }

  /// This application's binary, when it runs from its bundle: what the agents start as their web
  /// view's bridge, and what the `vibe` command runs.
  public nonisolated static func bundledExecutable() -> String? {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
    return Bundle.main.executablePath
  }

  /// Writes the session terminals' commands in the host's private directory, put in front of their
  /// `PATH`: `vibe`, pointing at this binary, and `open`, which sends a web page to the session's
  /// web view — how an agent that shows the user a page, as CLIs do with `open <url>`, shows it
  /// beside its terminal rather than in another application (#69). Anything else `open` is given,
  /// or a page when the application is not there, goes to macOS's own. Written again at each
  /// launch, so that they follow the application when it moves.
  private static func installCommand(
    at location: TerminalHostLocation, executable: String?
  ) -> URL? {
    guard let executable, (try? location.prepare()) != nil else { return nil }
    let directory = location.directory.appendingPathComponent("bin", isDirectory: true)
    let quoted = "'" + executable.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    let flag = BrowserBridge.commandLineFlag
    let scripts = [
      "vibe": "#!/bin/sh\nexec \(quoted) \(flag) \"$@\"\n",
      "open": """
      #!/bin/sh
      # A web page opened from a Vibe Manager session goes to the session's web view.
      if [ "$#" -eq 1 ]; then
        case "$1" in
          http://*|https://*)
            \(quoted) \(flag) browser open "$1" >/dev/null 2>&1 && exit 0
            ;;
        esac
      fi
      exec /usr/bin/open "$@"

      """,
    ]
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for (name, script) in scripts {
        let command = directory.appendingPathComponent(name, isDirectory: false)
        try Data(script.utf8).write(to: command, options: .atomic)
        chmod(command.path, 0o700)
      }
      return directory
    } catch {
      return nil
    }
  }

  /// The application's own binary, started with `--terminal-host`. `VIBE_TERMINAL_HOST=off` starts
  /// none — every terminal then runs in the application, as before ADR 0017 — which is how a
  /// development build keeps its agents inside the process a debugger is attached to.
  private static func hostLauncher(
    _ launch: Configuration.HostLaunch,
    logDirectory: URL,
    environment: [String: String]
  ) -> (any TerminalHostLaunching)? {
    switch launch {
    case .none:
      return nil
    case .launcher(let launcher):
      return launcher
    case .bundled:
      guard environment["VIBE_TERMINAL_HOST"] != "off" else { return nil }
      return ExecutableTerminalHostLauncher.bundled(logDirectory: logDirectory)
    }
  }

  struct DataLocation {
    let store: URL
    let runtime: URL
    let notes: URL
    let journal: URL
    let templates: URL
    let usage: URL
    let logs: URL
    /// The names given to groups (#27).
    let folders: URL
    /// The project icons of the sessions (#27).
    let icons: URL
    let defaultsSuite: String?
  }

  /// Where this copy of the application keeps what it writes.
  ///
  /// `VIBE_DATA_DIRECTORY` points a second copy at a folder of its own — its own store, its own
  /// runtime document, its own layout — so it can run beside the one the user works in without
  /// either taking the other for a second instance, or migrating the other's sessions.
  static func dataLocation(
    environment: [String: String], defaultsSuite: String?
  ) -> DataLocation {
    guard let directory = environment["VIBE_DATA_DIRECTORY"], directory.hasPrefix("/") else {
      return DataLocation(
        store: FileSessionRepository.defaultStoreURL(),
        runtime: FileSessionRuntimeStateStore.defaultURL(),
        notes: FileSessionNotesStore.defaultDirectory(),
        journal: FileSessionJournalStore.defaultDirectory(),
        templates: FilePromptTemplateRepository.defaultStoreURL(),
        usage: UsageStorage.defaultDirectory(),
        logs: DiagnosticsLocation.standard().directory,
        folders: FileFolderLabelStore.defaultURL(),
        icons: FileSessionIconStore.defaultDirectory(),
        defaultsSuite: defaultsSuite)
    }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    return DataLocation(
      store: folder.appendingPathComponent("sessions.json"),
      runtime: folder.appendingPathComponent("runtime.json"),
      notes: folder.appendingPathComponent("Notes", isDirectory: true),
      journal: folder.appendingPathComponent("Journal", isDirectory: true),
      templates: folder.appendingPathComponent("templates.json"),
      usage: folder.appendingPathComponent("Usage", isDirectory: true),
      logs: folder.appendingPathComponent("Logs", isDirectory: true),
      folders: folder.appendingPathComponent("folders.json"),
      icons: folder.appendingPathComponent("Icons", isDirectory: true),
      defaultsSuite: defaultsSuite ?? "com.hadrienl.VibeManager.isolated")
  }

  /// `VIBE_ENABLE_MOCK_AGENT=only` offers the mock alone, the way the interface smoke test runs:
  /// on a Mac with Claude Code or Codex installed, they would otherwise come first.
  private static func providers(
    environment: [String: String], diagnostics: any DiagnosticLog
  ) -> [any AgentProvider] {
    if environment["VIBE_ENABLE_MOCK_AGENT"] == "only" {
      return [MockAgentProvider(environment: environment)]
    }
    // One shell for both agents, asked as soon as the application starts: by the time the first
    // session is launched, its answer is usually there.
    let shell = LoginShellEnvironment(inherited: environment, probe: SystemProcessProbe())
    shell.warmUp()
    var providers: [any AgentProvider] = [
      ClaudeCodeAgentProvider.make(
        environment: environment, diagnostics: diagnostics, shellEnvironment: shell),
      CodexAgentProvider.make(
        environment: environment, diagnostics: diagnostics, shellEnvironment: shell),
    ]
    if MockAgentProvider.isEnabled(environment: environment) {
      providers.append(MockAgentProvider(environment: environment))
    }
    return providers
  }
}

/// When each session's agent started, read when it was launched or adopted.
@MainActor
private final class AgentProcessRegistry {
  private var processes: [SessionID: SessionProcess] = [:]

  func record(_ id: SessionID, _ pid: Int32) {
    guard let entry = ProcessAncestry.entry(of: pid) else { return }
    processes[id] = SessionProcess(
      sessionID: id, processIdentifier: pid,
      startedAt: ProcessStartTime(
        seconds: entry.startSeconds, microseconds: entry.startMicroseconds))
  }

  /// The agent the launcher says is running, as it was when it started. A process never recorded
  /// — which the launcher's callbacks leave no room for — is not trusted.
  func process(_ id: SessionID, _ pid: Int32) -> SessionProcess? {
    guard let process = processes[id], process.processIdentifier == pid else { return nil }
    return process
  }
}
