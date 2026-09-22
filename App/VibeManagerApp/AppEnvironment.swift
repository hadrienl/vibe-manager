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

  private let terminalSupervisor: PTYTerminalSupervisor
  private let launcher: SessionLauncher

  init() {
    let repository = FileSessionRepository()
    let registry = AgentProviderRegistry(providers: Self.providers())
    let supervisor = PTYTerminalSupervisor()

    terminalSupervisor = supervisor
    launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry
    )
    appModel = AppModel(
      repository: repository,
      recovery: repository,
      agents: registry,
      launcher: launcher,
      defaultWorkingDirectoryPath: AppEnvironment.defaultWorkingDirectory().path,
      layout: WorkspaceLayoutController(store: UserDefaultsWorkspaceLayoutStore())
    )
  }

  func stopAllTerminals() async {
    // The pending layout is written first: quitting is exactly when the delayed save that keeps
    // a separator drag cheap would otherwise be thrown away.
    await appModel.layout.flush()
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

  private static func defaultWorkingDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  }
}
