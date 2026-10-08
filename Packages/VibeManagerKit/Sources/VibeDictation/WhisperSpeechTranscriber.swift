import Foundation
import VibeApplication
import WhisperKit

/// Whisper on this Mac, through WhisperKit (#340): Core ML, the Neural Engine, nothing sent away.
///
/// The models are downloaded from `argmaxinc/whisperkit-coreml` into a folder of the application's
/// own, and kept there: the application's bundle, and so its updates, never carry one. A model is
/// installed once its download finished — a folder without the mark is a download interrupted,
/// started again from where it was.
public actor WhisperSpeechTranscriber: SpeechTranscribing {
  private static let repository = "argmaxinc/whisperkit-coreml"
  /// Written in a model's folder once all of it is downloaded.
  private static let completeMark = ".vibe-complete"

  /// The folder every model and their tokenizer are kept in.
  private let directory: URL
  private var loaded: (variant: DictationModelVariant, whisper: WhisperKit)?
  /// The load under way: a second caller waits for it rather than loading the model again — the
  /// actor lets callers in while it awaits.
  private var loading: (variant: DictationModelVariant, task: Task<LoadedWhisper, Error>)?

  public init(directory: URL) {
    self.directory = directory
  }

  /// Where a model's files are, as the hub client lays them out.
  nonisolated private func folder(of variant: DictationModelVariant) -> URL {
    directory
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(Self.repository, isDirectory: true)
      .appendingPathComponent(variant.repositoryFolder, isDirectory: true)
  }

  nonisolated public func installedSize(of variant: DictationModelVariant) -> Int64? {
    let folder = folder(of: variant)
    guard
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent(Self.completeMark).path)
    else { return nil }
    var total: Int64 = 0
    let files = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
    while let file = files?.nextObject() as? URL {
      let size = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        .totalFileAllocatedSize
      total += Int64(size ?? 0)
    }
    return total
  }

  public func download(
    _ variant: DictationModelVariant, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let folder = try await WhisperKit.download(
      variant: variant.repositoryFolder, downloadBase: directory, from: Self.repository
    ) { value in
      progress(value.fractionCompleted)
    }
    // Its tokenizer is downloaded with it, by a first load: a model must then work without a
    // network. The load is the preparation the user sees next, and is kept.
    try await load(variant, from: folder)
    FileManager.default.createFile(
      atPath: folder.appendingPathComponent(Self.completeMark).path, contents: Data())
  }

  public func prepare(_ variant: DictationModelVariant) async throws {
    guard loaded?.variant != variant else { return }
    try await load(variant, from: folder(of: variant))
  }

  @discardableResult
  private func load(_ variant: DictationModelVariant, from folder: URL) async throws -> WhisperKit {
    if let loading, loading.variant == variant { return try await loading.task.value.whisper }
    if let loaded {
      self.loaded = nil
      await loaded.whisper.unloadModels()
    }
    let config = WhisperKitConfig(
      downloadBase: directory, modelRepo: Self.repository, modelFolder: folder.path,
      tokenizerFolder: directory, verbose: false, prewarm: true, load: true, download: false)
    let task = Task { LoadedWhisper(whisper: try await WhisperKit(config)) }
    loading = (variant, task)
    defer { if loading?.variant == variant { loading = nil } }
    let whisper = try await task.value.whisper
    loaded = (variant, whisper)
    return whisper
  }

  public func transcribe(
    _ samples: [Float], with variant: DictationModelVariant, language: String?, prompt: String
  ) async throws -> String {
    let whisper: WhisperKit
    if let loaded, loaded.variant == variant {
      whisper = loaded.whisper
    } else {
      whisper = try await load(variant, from: folder(of: variant))
    }
    let options = DecodingOptions(
      language: language,
      detectLanguage: language == nil,
      skipSpecialTokens: true,
      withoutTimestamps: true,
      promptTokens: promptTokens(prompt, for: whisper),
      // Past thirty seconds, the audio is cut at its pauses rather than in the middle of a word.
      chunkingStrategy: .vad)
    let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
    return results.map(\.text).joined(separator: " ")
  }

  /// The prompt as the model reads it: its last tokens only. Whisper decodes at most 224 tokens a
  /// window, the prompt included, and each of its tokens is read before the first word is heard —
  /// a longer one would cut the end of a long dictation and slow every one down.
  private func promptTokens(_ prompt: String, for whisper: WhisperKit) -> [Int]? {
    guard !prompt.isEmpty, let tokenizer = whisper.tokenizer else { return nil }
    return Array(tokenizer.encode(text: " " + prompt).suffix(Self.promptTokenLimit))
  }

  /// Measured on an eleven seconds French prompt: about 0.6 s more than none, where the 200 tokens
  /// of a long prompt cost 2 s.
  private static let promptTokenLimit = 48

  public func remove(_ variant: DictationModelVariant) async throws {
    if loading?.variant == variant { _ = try? await loading?.task.value }
    if loaded?.variant == variant {
      await loaded?.whisper.unloadModels()
      loaded = nil
    }
    let folder = folder(of: variant)
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
    // The last model gone, nothing of dictation is left on disk: the tokenizers and the hub's
    // records of the downloads go with it.
    if DictationModelVariant.allCases.allSatisfy({ installedSize(of: $0) == nil }),
      FileManager.default.fileExists(atPath: directory.path)
    {
      try FileManager.default.removeItem(at: directory)
    }
  }
}

/// A model loaded, handed from the task that loads it to the actor that alone uses it.
private final class LoadedWhisper: @unchecked Sendable {
  let whisper: WhisperKit

  init(whisper: WhisperKit) {
    self.whisper = whisper
  }
}
