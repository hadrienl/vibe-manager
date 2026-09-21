import Foundation
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
    case failed(message: String, canRestoreBackup: Bool)
  }

  public private(set) var state: State = .idle

  private let loadSessions: LoadSessions
  private let recovery: (any SessionStoreRecovery)?

  public init(repository: any SessionRepository, recovery: (any SessionStoreRecovery)? = nil) {
    loadSessions = LoadSessions(repository: repository)
    self.recovery = recovery
  }

  public func load() async {
    guard state == .idle else { return }
    await reload()
  }

  /// Retries a load that failed; transient store failures are recoverable.
  public func reload() async {
    guard state != .loading else { return }

    state = .loading
    do {
      state = .loaded(try await loadSessions())
    } catch {
      state = await failure(for: error)
    }
  }

  public func restoreBackup() async {
    guard let recovery else { return }

    do {
      try await recovery.restoreBackup()
    } catch {
      state = await failure(for: error)
      return
    }
    await reload()
  }

  private func failure(for error: Error) async -> State {
    .failed(
      message: (error as? LocalizedError)?.errorDescription ?? "Unable to load work sessions.",
      canRestoreBackup: await recovery?.recoveryStatus() == .backupAvailable
    )
  }
}
