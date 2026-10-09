import Foundation

/// A voice that reads the agent's answers aloud (#357): one of the speakers Qwen3-TTS was trained
/// with. The names are the model's own, as is the description of each.
public enum SpeechVoice: String, CaseIterable, Codable, Sendable {
  case serena, vivian, ryan, aiden, eric, dylan, sohee
  case onoAnna = "ono-anna"
  case uncleFu = "uncle-fu"

  /// Its name as the model gives it: not translated.
  public var name: String {
    switch self {
    case .serena: "Serena"
    case .vivian: "Vivian"
    case .ryan: "Ryan"
    case .aiden: "Aiden"
    case .eric: "Eric"
    case .dylan: "Dylan"
    case .sohee: "Sohee"
    case .onoAnna: "Ono Anna"
    case .uncleFu: "Uncle Fu"
    }
  }
}

/// The languages the model reads, as it names them.
public enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
  case english, chinese, japanese, korean, german, french, russian, portuguese, spanish, italian

  /// Its ISO 639-1 code, to name it in the user's language.
  public var code: String {
    switch self {
    case .english: "en"
    case .chinese: "zh"
    case .japanese: "ja"
    case .korean: "ko"
    case .german: "de"
    case .french: "fr"
    case .russian: "ru"
    case .portuguese: "pt"
    case .spanish: "es"
    case .italian: "it"
    }
  }

  /// The language read by default: the user's, when the model reads it; English otherwise.
  public static func preferred(for locale: Locale = .current) -> SpeechLanguage {
    let code = locale.language.languageCode?.identifier ?? "en"
    return allCases.first { $0.code == code } ?? .english
  }
}

/// What the user chose for reading aloud.
public struct SpeechSettings: Equatable, Codable, Sendable {
  public var voice: SpeechVoice
  public var language: SpeechLanguage

  public init(voice: SpeechVoice = .serena, language: SpeechLanguage = .preferred()) {
    self.voice = voice
    self.language = language
  }
}

@MainActor
public protocol SpeechSettingsStore: AnyObject {
  var settings: SpeechSettings { get set }
}

@MainActor
public final class InMemorySpeechSettingsStore: SpeechSettingsStore {
  public var settings: SpeechSettings

  public init(settings: SpeechSettings = SpeechSettings()) {
    self.settings = settings
  }
}

/// A voice model on this Mac: downloaded once, then reading text aloud through the speakers.
public protocol SpeechSynthesizing: AnyObject, Sendable {
  /// What the model weighs on disk; `nil` when it is not downloaded.
  func installedSize() -> Int64?
  /// The download, about a gigabyte: said before it starts.
  var downloadSize: Int64 { get }
  func download(progress: @escaping @Sendable (Double) -> Void) async throws
  /// Loads the model, compiling it for this Mac's Neural Engine the first time a copy of the
  /// application loads it — minutes, the first time.
  func prepare() async throws
  /// Reads `text` aloud and returns once it is heard to its end. Cancelling the task stops the
  /// voice at once.
  func speak(_ text: String, voice: SpeechVoice, language: SpeechLanguage) async throws
  func remove() async throws
}

/// What is read of an answer: its sentences, without what a voice cannot say.
public enum SpeechText {
  /// `markdown` as prose: code blocks left out, the marks of emphasis, headings, lists, tables
  /// and links taken away, their words kept.
  public static func readable(fromMarkdown markdown: String) -> String {
    var lines: [String] = []
    var inFence = false
    for rawLine in markdown.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      guard !inFence else { continue }
      // A table's separator row, and the pipes of the others.
      if line.hasPrefix("|"), line.allSatisfy({ "|-: ".contains($0) }) { continue }
      var text = line
      text = text.replacingOccurrences(
        of: #"^(#{1,6}|[-*+]|\d+[.)]|>)\s+"#, with: "", options: .regularExpression)
      // A row of a table: its cells, one after the other.
      if text.hasPrefix("|") {
        text = text.split(separator: "|")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
          .joined(separator: ", ")
      }
      // [words](address) and ![words](address): the words.
      text = text.replacingOccurrences(
        of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
      // A lone underscore is left: it is more often in a name, `file_name`, than emphasis.
      text = text.replacingOccurrences(
        of: #"(\*\*|__|\*|~~|`)"#, with: "", options: .regularExpression)
      text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
      if text.isEmpty {
        if lines.last?.isEmpty == false { lines.append("") }
      } else {
        lines.append(text)
      }
    }
    // One paragraph a line, each ending as a sentence: the model pauses between them.
    return lines.split(separator: "")
      .map { paragraph in
        let joined = paragraph.joined(separator: " ")
        return joined.last.map { ".!?…:;".contains($0) } == true ? joined : joined + "."
      }
      .joined(separator: "\n")
  }
}

/// The pace of the voice on this Mac, learnt from its readings: how much to buffer before the
/// first word so that the voice is not cut, and no more.
public struct SpeechPace: Sendable {
  /// Seconds of audio generated per second of computation: just under 1 on an M2 Pro at rest.
  public private(set) var speed = 0.9
  /// Seconds of audio per character: about a fifteenth of a second in French.
  public private(set) var secondsPerCharacter = 0.065

  public init() {}

  /// What to buffer before `text` is heard: what the generation would fall behind over the whole
  /// of it, and a margin.
  public func buffer(for text: String) -> Double {
    let duration = Double(text.count) * secondsPerCharacter
    let behind = duration * max(0, 1 - speed)
    return min(max(behind + 0.4, 0.4), 6)
  }

  /// Learns from a reading: averaged with what was known, so that one slow reading — the Mac
  /// busy — does not slow every next one down.
  public mutating func record(text: String, audio: Double, generation: Double, wall: Double) {
    guard audio > 1, !text.isEmpty else { return }
    // The generation's own time when TTSKit gives it; the reading's otherwise, which includes
    // the playback and so understates the speed.
    let seconds = generation > 0 ? generation : wall
    if seconds > 0 { speed = (speed + audio / seconds) / 2 }
    secondsPerCharacter = (secondsPerCharacter + audio / Double(text.count)) / 2
  }
}
