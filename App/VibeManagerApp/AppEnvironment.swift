import VibePersistence
import VibeUI

@MainActor
final class AppEnvironment {
  let appModel: AppModel

  init() {
    let repository = InMemorySessionRepository()
    appModel = AppModel(repository: repository)
  }
}
