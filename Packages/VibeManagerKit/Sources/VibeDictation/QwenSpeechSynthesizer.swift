import Foundation
import OSLog
import TTSKit
import VibeApplication

/// Qwen3-TTS 0.6B on this Mac, through TTSKit (#357): Core ML, played as it is generated.
///
/// The model is downloaded into a folder of the application's own, as Whisper's is, and kept
/// there; it is installed once its download finished. TTSKit needs macOS 15: on macOS 14 the
/// application reads nothing aloud.
@available(macOS 15.0, *)
public actor QwenSpeechSynthesizer: SpeechSynthesizing {
  private static let completeMark = ".vibe-complete"

  private let directory: URL
  private var tts: TTSKit?
  /// The model being loaded, for every caller to wait for.
  private var loading: Task<TTSKit, Error>?
  /// The reading being played, until its player is torn down: TTSKit has one player, not made to
  /// be shared, and the next reading waits for it.
  private var playing: Task<Void, Never>?
  /// How fast the model speaks for this Mac, measured on the readings before: seconds of audio
  /// generated per second, and seconds of audio per character of text.
  private var pace = SpeechPace()

  public init(directory: URL) {
    self.directory = directory
  }

  nonisolated public var downloadSize: Int64 { 1_000_000_000 }

  nonisolated private var mark: URL {
    directory.appendingPathComponent(Self.completeMark, isDirectory: false)
  }

  nonisolated public func installedSize() -> Int64? {
    guard installedFolder() != nil else { return nil }
    var total: Int64 = 0
    let files = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
    while let file = files?.nextObject() as? URL {
      let size = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        .totalFileAllocatedSize
      total += Int64(size ?? 0)
    }
    return total
  }

  public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let folder = try await TTSKit.download(variant: .qwen3TTS_0_6b, downloadBase: directory) {
        value in progress(value.fractionCompleted)
      }
      // Loaded once now: the compilation for this Mac is the preparation the user waits for, and
      // the first reading starts at once.
      _ = try await loaded(from: folder)
      // The mark keeps where the model is, relative to the directory: a model is loaded from its
      // folder, never downloaded again to find it.
      let relative = folder.standardizedFileURL.path
        .replacingOccurrences(of: directory.standardizedFileURL.path + "/", with: "")
      FileManager.default.createFile(atPath: mark.path, contents: Data(relative.utf8))
    } catch {
      // What failed — the network, the disk, the compilation — is said in the system's log: the
      // interface only says that it failed.
      Self.log.error("Voice model not installed: \(String(describing: error), privacy: .public)")
      throw error
    }
  }

  private static let log = Logger(subsystem: "eu.hadrien.VibeManager", category: "speech")

  public func prepare() async throws {
    _ = try await loaded()
  }

  public func prepare(voice: SpeechVoice, language: SpeechLanguage) async throws {
    let tts = try await loaded()
    // Kept by TTSKit and reused by every reading in this voice and language.
    _ = try await tts.buildPromptCache(
      speaker: Qwen3Speaker(rawValue: voice.rawValue) ?? .serena,
      language: Qwen3Language(rawValue: language.rawValue) ?? .english)
  }

  /// The model, loaded from `folder`, or from the one its mark keeps. Loaded once: a caller that
  /// comes while it loads — a reading asked for during the warm-up — waits for the same loading.
  private func loaded(from folder: URL? = nil) async throws -> TTSKit {
    if let tts { return tts }
    if let loading { return try await loading.value }
    guard let folder = folder ?? installedFolder() else { throw SpeechModelError.notInstalled }
    let directory = directory
    let loading = Task {
      try await ModelLoading.shared.run("voice") {
        let tts = try await TTSKit(
          TTSKitConfig(
            model: .qwen3TTS_0_6b, modelFolder: folder, downloadBase: directory, verbose: false,
            download: false))
        try await tts.loadModels()
        return tts
      }
    }
    self.loading = loading
    defer { if self.loading == loading { self.loading = nil } }
    let tts = try await loading.value
    // Removed while it loaded: the model is not kept.
    guard self.loading == loading else {
      await tts.unloadModels()
      throw SpeechModelError.notInstalled
    }
    self.tts = tts
    return tts
  }

  /// The folder the mark names.
  nonisolated private func installedFolder() -> URL? {
    guard let data = FileManager.default.contents(atPath: mark.path),
      let relative = String(data: data, encoding: .utf8), !relative.isEmpty
    else { return nil }
    return directory.appendingPathComponent(relative, isDirectory: true)
  }

  enum SpeechModelError: Error {
    case notInstalled
  }

  public func speak(_ text: String, voice: SpeechVoice, language: SpeechLanguage) async throws {
    let tts = try await loaded()
    // The reading before is over — stopped, its player torn down — before this one starts its own.
    while let before = playing {
      await before.value
      if playing == before { playing = nil }
    }
    try Task.checkCancellation()
    var options = GenerationOptions()
    // One sentence after the other: the order a voice reads in.
    options.concurrentWorkerCount = 1
    // TTSKit's own `.auto` buffers for the longest a sentence may be, at the pace of its first,
    // slowest steps: ten seconds and more before a word. Buffered here for this text, at the pace
    // measured on the readings before.
    let buffer = pace.buffer(for: text)
    let start = Date()
    let reading = Task {
      try await tts.play(
        text: text,
        voice: (Qwen3Speaker(rawValue: voice.rawValue) ?? .serena).rawValue,
        language: (Qwen3Language(rawValue: language.rawValue) ?? .english).rawValue,
        options: options, playbackStrategy: .buffered(seconds: buffer)
      ) { _ in Task.isCancelled ? false : true }
    }
    let cut = PlaybackCut()
    playing = Task {
      _ = await reading.result
      // Stopped: the cut silenced what was generated ahead; the player is torn down after it.
      await cut.finish()?.value
      await tts.audioOutput.stopPlayback(waitForCompletion: false)
    }
    let result = try await withTaskCancellationHandler {
      try await reading.value
    } onCancel: {
      reading.cancel()
      // Stopped now: what was generated ahead is not played to its end.
      cut.cut { await tts.audioOutput.stopPlayback(waitForCompletion: false) }
    }
    pace.record(
      text: text, audio: result.audioDuration, generation: result.timings.fullPipeline,
      wall: Date().timeIntervalSince(start))
  }

  public func remove() async throws {
    // A loading under way is dropped: what it loads is not kept.
    if let loading {
      self.loading = nil
      _ = await loading.result
    }
    if let tts {
      self.tts = nil
      await tts.unloadModels()
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
}

/// The voice silenced at once when its reading is cancelled, and the reading's end waiting for it:
/// the next reading's player is never the one the cut stops.
private final class PlaybackCut: @unchecked Sendable {
  private let lock = NSLock()
  private var isFinished = false
  private var stop: Task<Void, Never>?

  /// Starts `silence`, unless the reading is already over.
  func cut(_ silence: @escaping @Sendable () async -> Void) {
    lock.withLock {
      guard !isFinished else { return }
      stop = Task { await silence() }
    }
  }

  /// The reading is over: no cut starts after this; the one started, if any, to wait for.
  func finish() -> Task<Void, Never>? {
    lock.withLock {
      isFinished = true
      return stop
    }
  }
}
