import Foundation
import VibeAgents
import VibeApplication
import VibePersistence
import VibeUI

@MainActor
final class AppEnvironment {
  let appModel: AppModel

  init() {
    let repository = FileSessionRepository()
    let registry = AgentProviderRegistry(providers: Self.providers())
    appModel = AppModel(repository: repository, recovery: repository, agents: registry)
  }

  /// The only place a provider is registered. Adding an agent stops here.
  private static func providers() -> [any AgentProvider] {
    var providers: [any AgentProvider] = []
    if MockAgentProvider.isEnabled() {
      providers.append(MockAgentProvider())
    }
    return providers
  }
}
