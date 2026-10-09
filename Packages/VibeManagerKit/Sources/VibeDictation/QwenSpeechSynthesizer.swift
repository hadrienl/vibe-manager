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

  /// The model, loaded from `folder`, or from the one its mark keeps.
  private func loaded(from folder: URL? = nil) async throws -> TTSKit {
    if let tts { return tts }
    guard let folder = folder ?? installedFolder() else { throw SpeechModelError.notInstalled }
    let tts = try await TTSKit(
      TTSKitConfig(
        model: .qwen3TTS_0_6b, modelFolder: folder, downloadBase: directory, verbose: false,
        download: false))
    try await tts.loadModels()
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
    var options = GenerationOptions()
    // One sentence after the other: the order a voice reads in.
    options.concurrentWorkerCount = 1
    try await withTaskCancellationHandler {
      _ = try await tts.play(
        text: text,
        voice: (Qwen3Speaker(rawValue: voice.rawValue) ?? .serena).rawValue,
        language: (Qwen3Language(rawValue: language.rawValue) ?? .english).rawValue,
        options: options, playbackStrategy: .auto
      ) { _ in Task.isCancelled ? false : true }
    } onCancel: {
      // Stopped now: what was generated ahead is not played to its end.
      Task { await tts.audioOutput.stopPlayback(waitForCompletion: false) }
    }
  }

  public func remove() async throws {
    if let tts {
      await tts.unloadModels()
      self.tts = nil
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
}
