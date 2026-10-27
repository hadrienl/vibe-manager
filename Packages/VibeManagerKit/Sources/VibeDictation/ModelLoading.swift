import Foundation
import OSLog

/// One model loaded at a time (#357). Whisper and the voice both compile for the Neural Engine
/// the first time a copy of the application loads them; two at once were seen to wait on each
/// other for minutes, the transcription asked for never done.
actor ModelLoading {
  static let shared = ModelLoading()

  private var last: Task<Void, Never>?

  /// Runs `load` once the loads asked for before it are done.
  func run<T: Sendable>(_ name: String, _ load: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    let previous = last
    let task = Task<T, Error> {
      await previous?.value
      let start = Date()
      voiceLog.notice("Loading \(name, privacy: .public)")
      do {
        let value = try await load()
        voiceLog.notice(
          "Loaded \(name, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 1)) s"
        )
        return value
      } catch {
        voiceLog.error(
          "\(name, privacy: .public) not loaded: \(String(describing: error), privacy: .public)")
        throw error
      }
    }
    last = Task { _ = try? await task.value }
    return try await task.value
  }
}

let voiceLog = Logger(subsystem: "eu.hadrien.VibeManager", category: "voice")
