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
  let terminalPane: TerminalPaneModel

  private let terminalSupervisor: PTYTerminalSupervisor

  init() {
    let repository = FileSessionRepository()
    let registry = AgentProviderRegistry(providers: Self.providers())
    appModel = AppModel(repository: repository, recovery: repository, agents: registry)

    let supervisor = PTYTerminalSupervisor()
    terminalSupervisor = supervisor
    terminalPane = TerminalPaneModel(
      sessionID: SessionID(),
      supervisor: supervisor,
      spec: .loginShell(workingDirectoryURL: AppEnvironment.defaultWorkingDirectory())
    )
  }

  // Quitting must not leave agent processes behind, so termination waits for the graceful stop
  // of every terminal before the application actually exits.
  func stopAllTerminals() async {
    await terminalSupervisor.stopAll(gracePeriod: .seconds(3))
  }

  /// The only place a provider is registered. Adding an agent stops here.
  private static func providers() -> [any AgentProvider] {
    var providers: [any AgentProvider] = []
    if MockAgentProvider.isEnabled() {
      providers.append(MockAgentProvider())
    }
    return providers
  }

  private static func defaultWorkingDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  }
}
