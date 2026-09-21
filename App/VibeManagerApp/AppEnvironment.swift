import VibePersistence
import VibeUI

@MainActor
final class AppEnvironment {
  let appModel: AppModel

  init() {
    let repository = FileSessionRepository()
    appModel = AppModel(repository: repository)
  }
}
