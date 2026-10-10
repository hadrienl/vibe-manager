import Foundation

/// A speech model the composer's dictation can run (#340): Whisper, on this Mac, downloaded once.
///
/// None ships with the application: a model weighs hundreds of megabytes, which every update would
/// carry for users who never dictate. The first dictation offers to download the one chosen.
public enum DictationModelVariant: String, CaseIterable, Codable, Sendable {
  /// Lighter, for a Mac short of memory; it stumbles on jargon.
  case small
  /// Whisper large-v3 turbo, compressed: the default, and the one whose French holds.
  case largeTurbo

  /// Its folder in the repository WhisperKit downloads from, `argmaxinc/whisperkit-coreml`.
  public var repositoryFolder: String {
    switch self {
    case .small: "openai_whisper-small_216MB"
    case .largeTurbo: "openai_whisper-large-v3-v20240930_626MB"
    }
  }

  /// What it weighs once downloaded, as its repository names it: said before it is downloaded.
  public var downloadSize: Int64 {
    switch self {
    case .small: 216_000_000
    case .largeTurbo: 626_000_000
    }
  }
}

/// What the user chose for dictation.
public struct DictationSettings: Equatable, Codable, Sendable {
  public var variant: DictationModelVariant
  /// A Whisper language code, `fr`, `en`… `nil` lets the model tell which language it hears.
  public var language: String?

  public init(variant: DictationModelVariant = .largeTurbo, language: String? = nil) {
    self.variant = variant
    self.language = language
  }

  /// The languages offered by name: the application's own. Whisper knows more, but a list of a
  /// hundred buries the few anyone means, and "Automatic" hears the others.
  public static let languages = [
    "ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt", "ru", "tr", "uk", "zh",
  ]
}

/// Where the choice is kept.
@MainActor
public protocol DictationSettingsStore: AnyObject {
  var settings: DictationSettings { get set }
}

@MainActor
public final class InMemoryDictationSettingsStore: DictationSettingsStore {
  public var settings: DictationSettings

  public init(settings: DictationSettings = DictationSettings()) {
    self.settings = settings
  }
}

/// Whether the application may hear the microphone.
public enum MicrophoneAccess: Sendable, Equatable {
  case granted
  case denied
  /// Never asked: the system asks the first time it is opened.
  case undetermined
}

/// The microphone, recorded as Whisper hears: mono, at 16 kHz, in samples between -1 and 1.
@MainActor
public protocol AudioRecording: AnyObject {
  var access: MicrophoneAccess { get }
  /// Asks the system, which asks the user once; `true` when granted.
  func requestAccess() async -> Bool
  /// Opens the microphone. `cancellingEcho` filters out what the Mac itself plays — the voice
  /// reading an answer — so that a discussion does not hear it as the user (#357).
  func start(cancellingEcho: Bool) throws
  /// What was heard since the last call, the microphone left open.
  func takeSamples() -> [Float]
  /// Stops and gives back everything heard since `start`, or since the last `takeSamples`.
  func stop() -> [Float]
}

extension AudioRecording {
  public func start() throws { try start(cancellingEcho: false) }
}

/// A speech model on this Mac: downloaded, loaded, and asked what was said.
public protocol SpeechTranscribing: AnyObject, Sendable {
  /// What the model weighs on disk; `nil` when it is not downloaded.
  func installedSize(of variant: DictationModelVariant) -> Int64?
  /// Downloads the model, `progress` going from 0 to 1. A download interrupted is started again.
  func download(
    _ variant: DictationModelVariant, progress: @escaping @Sendable (Double) -> Void
  ) async throws
  /// Loads the model, compiling it for this Mac the first time — which can take a minute.
  func prepare(_ variant: DictationModelVariant) async throws
  /// What was said in `samples`, guided by `prompt`: the words the speaker is likely to use.
  func transcribe(
    _ samples: [Float], with variant: DictationModelVariant, language: String?, prompt: String
  ) async throws -> String
  /// Deletes the model from the disk, and forgets it if it was loaded.
  func remove(_ variant: DictationModelVariant) async throws
}

/// What dictation does with what it heard, before and after the model: pure, so it is tested.
public enum DictationTranscript {
  /// Samples per second, as Whisper hears.
  public static let sampleRate = 16_000

  /// Whether anything louder than the room was heard. Whisper given a silence makes up a sentence
  /// — in French, the credits of the subtitles it was trained on — so a silence is never given to
  /// it: the loudest tenth of a second must stand above the background noise.
  public static func containsSpeech(_ samples: [Float]) -> Bool {
    let window = sampleRate / 10
    guard samples.count >= window else { return false }
    var loudest: Float = 0
    var start = 0
    while start + window <= samples.count {
      var sum: Float = 0
      for sample in samples[start..<start + window] { sum += sample * sample }
      loudest = max(loudest, (sum / Float(window)).squareRoot())
      start += window
    }
    return loudest >= speechThreshold
  }

  /// The root mean square of a tenth of a second that is speech: a voice at a normal distance
  /// from a laptop's microphone stands well above it, a quiet room well below.
  static let speechThreshold: Float = 0.015

  /// The sentences Whisper is known to make up over a pause — the credits and sign-offs of the
  /// videos it learnt from — taken out of what it heard. Compared without case or punctuation.
  static let hallucinations = [
    "sous-titres réalisés par la communauté d'amara.org",
    "sous-titrage st' 501",
    "sous-titrage société radio-canada",
    "merci d'avoir regardé cette vidéo",
    "thank you for watching",
    "thanks for watching",
    "subtitles by the amara.org community",
  ]

  /// The text to insert: what the model said, without the sentence it made up over the pause
  /// that ends it. Only a sentence of its own is taken out — the whole text, or its last
  /// sentence: the same words said within a sentence are the user's.
  public static func cleaned(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let ending = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
    for phrase in hallucinations {
      let body = result.trimmingCharacters(in: ending)
      guard
        let range = body.range(
          of: phrase, options: [.caseInsensitive, .diacriticInsensitive, .anchored, .backwards])
      else { continue }
      let before = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
      // The phrase is its own sentence: the text, or after the end of another.
      guard before.isEmpty || before.last.map({ ".!?…".contains($0) }) == true else { continue }
      result = before
    }
    // A pause written as a lone ellipsis or full stop is no text.
    return result.unicodeScalars.allSatisfy(ending.contains) ? "" : result
  }

  /// `text` as it is inserted between two characters of the draft: a space on either side where
  /// it would otherwise touch a word.
  public static func spaced(_ text: String, after previous: Character?, before next: Character?)
    -> String
  {
    var result = text
    if let previous, !previous.isWhitespace { result = " " + result }
    if let next, !next.isWhitespace, !next.isPunctuation { result += " " }
    return result
  }

  /// The words the speaker is likely to say, given to the model as the text that came before:
  /// the terms of the trade, a few files at the root of the project, its branch and its name.
  /// Whisper keeps the end of a prompt, and every word of it costs time before the first one heard
  /// is written: it is kept short, the most particular words last, so they are the ones kept.
  public static func prompt(projectName: String?, branch: String?, fileNames: [String]) -> String {
    var words = commonTerms
    words.append(contentsOf: fileNames.prefix(5))
    if let branch, !branch.isEmpty { words.append(branch) }
    if let projectName, !projectName.isEmpty { words.append(projectName) }
    var seen = Set<String>()
    let unique = words.filter { seen.insert($0).inserted }
    var prompt = unique.joined(separator: ", ")
    while prompt.count > maximumPromptLength, let comma = prompt.firstIndex(of: ",") {
      prompt = String(prompt[prompt.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
    }
    return prompt
  }

  /// About fifty tokens: what the transcriber keeps of a prompt.
  static let maximumPromptLength = 200

  /// The words of a developer's prompts that a general model writes wrong.
  static let commonTerms = [
    "Claude Code", "Codex", "commit", "pull request", "CI", "GitHub", "worktree", "build",
  ]
}

/// Where a sentence begins and ends in what the microphone hears, for the discussion (#357): a
/// voice louder than the room for a moment begins one, a pause ends it. Pure, so it is tested.
public struct UtteranceDetector: Sendable {
  public enum Event: Equatable, Sendable {
    /// The user began to speak.
    case speechStarted
    /// A sentence ended with a pause: its samples, from a little before its first word.
    case utterance([Float])
  }

  /// A tenth of a second: what each loudness is measured on.
  static let frame = DictationTranscript.sampleRate / 10
  /// So long above the room to begin a sentence: a cough or a click does not.
  static let speechFrames = 3
  /// So long a pause to end it.
  public static let pauseFrames = 12
  /// What is kept from before the first loud frame: the start of the first word.
  static let leadFrames = 3
  /// A sentence never lasts longer: past it, it is ended where it is.
  static let longestFrames = 600

  /// The loudness of the room, learnt while nobody speaks.
  private var noise: Float = 0.005
  public private(set) var level: Float = 0
  private var carry: [Float] = []
  private var lead: [[Float]] = []
  private var loud = 0
  private var quiet = 0
  private var sentence: [Float]?
  private var sentenceFrames = 0

  public init() {}

  public var isHearingSpeech: Bool { sentence != nil }

  /// What a voice must stand above: the room's noise, three times over — and much more while the
  /// Mac speaks, so that only the user cutting in is heard over the echo the filter lets through.
  func threshold(whileSpeaking: Bool) -> Float {
    whileSpeaking ? max(0.04, noise * 8) : max(0.015, noise * 3)
  }

  /// Feeds what was heard; `whileSpeaking` when the voice reads an answer.
  public mutating func feed(_ samples: [Float], whileSpeaking: Bool = false) -> [Event] {
    var events: [Event] = []
    carry.append(contentsOf: samples)
    while carry.count >= Self.frame {
      let frame = Array(carry.prefix(Self.frame))
      carry.removeFirst(Self.frame)
      var sum: Float = 0
      for sample in frame { sum += sample * sample }
      let rms = (sum / Float(frame.count)).squareRoot()
      level = rms
      let isLoud = rms >= threshold(whileSpeaking: whileSpeaking)
      if var current = sentence {
        current.append(contentsOf: frame)
        sentenceFrames += 1
        quiet = isLoud ? 0 : quiet + 1
        if quiet >= Self.pauseFrames || sentenceFrames >= Self.longestFrames {
          // The pause itself is not part of it, but for its first tenth.
          let trailing = max(0, quiet - 1) * Self.frame
          events.append(.utterance(Array(current.dropLast(trailing))))
          sentence = nil
          quiet = 0
          loud = 0
          lead = []
        } else {
          sentence = current
        }
        continue
      }
      if isLoud {
        loud += 1
        lead.append(frame)
        if loud >= Self.speechFrames {
          sentence = lead.suffix(Self.leadFrames + Self.speechFrames).flatMap { $0 }
          sentenceFrames = loud
          quiet = 0
          events.append(.speechStarted)
        }
      } else {
        loud = 0
        lead.append(frame)
        if lead.count > Self.leadFrames { lead.removeFirst(lead.count - Self.leadFrames) }
        // The room is learnt from its quiet frames only, slowly.
        noise = noise * 0.95 + rms * 0.05
      }
    }
    return events
  }

  /// Whether a sentence asks the agent to stop rather than says something to it.
  public static func isStop(_ text: String) -> Bool {
    let words = text.lowercased()
      .folding(options: .diacriticInsensitive, locale: nil)
      .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    return ["stop", "arrete", "arrete-toi", "stoppe", "halt"].contains(words)
  }
}
