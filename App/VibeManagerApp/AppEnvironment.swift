import Foundation
import VibeAgents
import VibeApplication
import VibeDomain
import VibeGit
import VibePersistence
import VibeTerminal
import VibeTerminalUI
import VibeUI

@MainActor
final class AppEnvironment {
  let appModel: AppModel
  /// Held here as well as inside the model: the settings window is a scene of its own, and it
  /// must read the same status the workspace read rather than probe the system a second time.
  let permissions: PermissionsModel

  private let terminalSupervisor: HostedTerminalSupervisor
  private let launcher: SessionLauncher
  private let prepareForQuit: PrepareForQuit
  private let detachForQuit: DetachForQuit

  init() {
    let data = Self.dataLocation()
    let repository = FileSessionRepository(storeURL: data.store)
    let notes = FileSessionNotesStore(directory: data.notes)
    let registry = AgentProviderRegistry(providers: Self.providers())
    // Every terminal runs in the terminal host, so its agent can be left running when the
    // application quits (ADR 0017). One host per data directory: an isolated copy has its own.
    let supervisor = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: TerminalHostLocation(dataDirectory: data.store.deletingLastPathComponent()),
        launcher: Self.hostLauncher(),
        verifier: CodeSigningPeerVerifier()
      )
    )

    terminalSupervisor = supervisor
    // The runtime document: what this copy of the application is running, so the next launch can
    // tell a quit from a crash and knows what to put back to work. Deliberately a document of its
    // own, next to the session store and never inside it.
    let recorder = SessionRuntimeRecorder(store: FileSessionRuntimeStateStore(url: data.runtime))
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry,
      recorder: recorder
    )
    self.launcher = launcher
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
        probe: TCCFullDiskAccessProbe(),
        preferences: UserDefaultsPermissionPreferences()
      )
    )
    self.permissions = permissions
    let transcripts = AgentTranscriptReader()
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
      branchReader: ReadSessionBranchReport(reader: GitActivityReader(), transcripts: transcripts),
      // Read only as well, and only when the disk says something moved: no timer reads a
      // repository. One transcript reader for both, so each file is read once, incrementally.
      repositoryStatus: RepositoryStatusMonitor(
        reader: GitStatusReader(),
        events: FSEventsFileChangeObserver(),
        transcripts: transcripts
      ),
      closePreferences: UserDefaultsSessionClosePreferences(suiteName: data.defaultsSuite),
      fileOpeningPreferences: UserDefaultsFileOpeningPreferences(suiteName: data.defaultsSuite),
      notesStore: notes,
      notesFileLocation: { notes.fileURL(for: $0) },
      quitPreferences: UserDefaultsQuitPreferences(suiteName: data.defaultsSuite),
      templateRepository: FilePromptTemplateRepository(storeURL: data.templates),
      templateExchange: PromptTemplateExchangeCodec()
    )
  }

  /// Sessions whose agent could be left running when the application quits.
  var hostedRunningCount: Int {
    launcher.hostedRunningCount
  }

  /// Sessions whose agent runs inside the application, and will stop with it regardless.
  var inProcessRunningCount: Int {
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
  func shutdown(keepingAgentsRunning: Bool) async {
    // The pending layout is written first: quitting is exactly when the delayed save that keeps
    // a separator drag cheap would otherwise be thrown away.
    await appModel.layout.flush()
    // No FSEvents stream and no new `git status` outlive the window they were reading for.
    await appModel.stopWatchingRepositories()
    // A restoration under way is called off *and waited for*: cancelling only asks, and a resume
    // already in flight would otherwise write `reopen` after this shutdown had decided what to
    // close.
    await appModel.stopRestoring()
    if keepingAgentsRunning {
      await detachForQuit()
      return
    }
    await prepareForQuit()
    await launcher.stopAll()
    await terminalSupervisor.stopAll(gracePeriod: .seconds(3))
    // Said rather than left to the host to infer: a client that simply vanished reads as a crash.
    await terminalSupervisor.relinquish(keepRunning: false)
  }

  /// The application's own binary, started with `--terminal-host`. `VIBE_TERMINAL_HOST=off` starts
  /// none — every terminal then runs in the application, as before ADR 0017 — which is how a
  /// development build keeps its agents inside the process a debugger is attached to.
  private static func hostLauncher(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> (any TerminalHostLaunching)? {
    guard environment["VIBE_TERMINAL_HOST"] != "off" else { return nil }
    return ExecutableTerminalHostLauncher.bundled()
  }

  /// Where this copy of the application keeps what it writes.
  ///
  /// `VIBE_DATA_DIRECTORY` points a second copy at a folder of its own — its own store, its own
  /// runtime document, its own layout — so it can run beside the one the user works in without
  /// either taking the other for a second instance, or migrating the other's sessions.
  private static func dataLocation(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> (store: URL, runtime: URL, notes: URL, templates: URL, defaultsSuite: String?) {
    guard let directory = environment["VIBE_DATA_DIRECTORY"], directory.hasPrefix("/") else {
      return (
        FileSessionRepository.defaultStoreURL(), FileSessionRuntimeStateStore.defaultURL(),
        FileSessionNotesStore.defaultDirectory(), FilePromptTemplateRepository.defaultStoreURL(),
        nil
      )
    }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    return (
      folder.appendingPathComponent("sessions.json"),
      folder.appendingPathComponent("runtime.json"),
      folder.appendingPathComponent("Notes", isDirectory: true),
      folder.appendingPathComponent("templates.json"),
      "com.hadrienl.VibeManager.isolated"
    )
  }

  private static func providers() -> [any AgentProvider] {
    var providers: [any AgentProvider] = [
      ClaudeCodeAgentProvider.make(),
      CodexAgentProvider.make(),
    ]
    if MockAgentProvider.isEnabled() {
      providers.append(MockAgentProvider())
    }
    return providers
  }
}
