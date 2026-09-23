import Foundation
import VibeAgents
import VibeApplication
import VibeDomain
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

  private let terminalSupervisor: PTYTerminalSupervisor
  private let launcher: SessionLauncher
  private let prepareForQuit: PrepareForQuit

  init() {
    let repository = FileSessionRepository()
    let registry = AgentProviderRegistry(providers: Self.providers())
    let supervisor = PTYTerminalSupervisor()

    terminalSupervisor = supervisor
    // The runtime document: what this copy of the application is running, so the next launch can
    // tell a quit from a crash and knows what to put back to work. Deliberately a document of its
    // own, next to the session store and never inside it.
    let recorder = SessionRuntimeRecorder(store: FileSessionRuntimeStateStore())
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
    // The only permission the application ever asks for, wired to the system that answers it:
    // the TCC witness for the status, the user defaults for the answer already given.
    let permissions = PermissionsModel(
      gate: FullDiskAccessGate(
        probe: TCCFullDiskAccessProbe(),
        preferences: UserDefaultsPermissionPreferences()
      )
    )
    self.permissions = permissions
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
      layout: WorkspaceLayoutController(store: UserDefaultsWorkspaceLayoutStore()),
      permissions: permissions,
      runtimeRecorder: recorder
    )
  }

  /// Everything quitting owes the next launch, in the order it is owed.
  ///
  /// The sessions are stopped and closed **before** the intention to resume them is written, so
  /// that intention can only name sessions that really stopped. The two `stopAll` calls behind it
  /// are the safety net: a terminal the launcher never knew about, or a session the store could
  /// not be asked about, still has its process taken down.
  func shutdown() async {
    // The pending layout is written first: quitting is exactly when the delayed save that keeps
    // a separator drag cheap would otherwise be thrown away.
    await appModel.layout.flush()
    // A restoration under way is called off *and waited for*: cancelling only asks, and a resume
    // already in flight would otherwise write `reopen` after this shutdown had decided what to
    // close.
    await appModel.stopRestoring()
    await prepareForQuit()
    await launcher.stopAll()
    await terminalSupervisor.stopAll(gracePeriod: .seconds(3))
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
