import Observation
import VibeApplication
import VibeDomain

@MainActor
@Observable
public final class AppModel {
  public enum State: Equatable {
    case idle
    case loading
    case loaded([WorkSession])
    case failed(message: String)
  }

  public private(set) var state: State = .idle

  private let loadSessions: LoadSessions

  public init(repository: any SessionRepository) {
    loadSessions = LoadSessions(repository: repository)
  }

  public func load() async {
    guard state == .idle else { return }

    state = .loading
    do {
      state = .loaded(try await loadSessions())
    } catch {
      state = .failed(message: "Unable to load work sessions.")
    }
  }
}
