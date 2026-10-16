import Foundation

/// What a composed sound plays (#393): a few voices of simple waves, their notes, and an echo.
/// What an agent answers, held to `AlertSoundSchema.forAgent`, and checked by `problems` — a
/// schema cannot say how long a sound lasts. The application plays it with
/// `AlertSoundSynthesizer`: the agent never runs anything.
public struct AlertSoundRecipe: Hashable, Sendable, Codable {
  public enum Wave: String, Hashable, Sendable, Codable, CaseIterable {
    case sine, triangle, square, sawtooth, noise
  }

  public struct Note: Hashable, Sendable, Codable {
    /// When it starts, in seconds from the start of the sound.
    public var start: Double
    /// How long it is held, in seconds, before its release.
    public var length: Double
    /// A note name, `C0` to `B8` (`C4` is middle C), with `#` or `b`: `E5`, `F#3`, `Bb4`.
    public var pitch: String

    public init(start: Double, length: Double, pitch: String) {
      self.start = start
      self.length = length
      self.pitch = pitch
    }
  }

  public struct Voice: Hashable, Sendable, Codable {
    public var wave: Wave
    /// How loud, from 0 to 1, before the sound is brought to its level.
    public var gain: Double
    /// The envelope of each note: seconds, then the level held (0 to 1), then seconds.
    public var attack: Double
    public var decay: Double
    public var sustain: Double
    public var release: Double
    /// A low-pass filter's cutoff in Hz, softening the voice; `nil` for none.
    public var cutoff: Double?
    public var notes: [Note]

    public init(
      wave: Wave, gain: Double, attack: Double, decay: Double, sustain: Double, release: Double,
      cutoff: Double? = nil, notes: [Note]
    ) {
      self.wave = wave
      self.gain = gain
      self.attack = attack
      self.decay = decay
      self.sustain = sustain
      self.release = release
      self.cutoff = cutoff
      self.notes = notes
    }
  }

  public struct Echo: Hashable, Sendable, Codable {
    /// Seconds between two repeats.
    public var delay: Double
    /// How much of each repeat comes back, from 0 to 0.9.
    public var feedback: Double
    /// How loud the repeats are beside the sound itself, from 0 to 1.
    public var mix: Double

    public init(delay: Double, feedback: Double, mix: Double) {
      self.delay = delay
      self.feedback = feedback
      self.mix = mix
    }
  }

  /// A short name in the user's language.
  public var name: String
  public var voices: [Voice]
  public var echo: Echo?

  public init(name: String, voices: [Voice], echo: Echo? = nil) {
    self.name = name
    self.voices = voices
    self.echo = echo
  }

  // MARK: - Bounds

  public static let maximumDuration: Double = 3
  public static let maximumVoices = 4
  public static let maximumNotes = 16
  static let attackRange = 0.0...1.0
  static let decayRange = 0.0...2.0
  static let releaseRange = 0.0...2.0
  static let lengthRange = 0.01...3.0
  static let cutoffRange = 100.0...16_000.0
  static let delayRange = 0.02...1.0
  static let feedbackRange = 0.0...0.9
  static let unitRange = 0.0...1.0
  static let frequencyRange = 25.0...8_000.0

  /// How long the sound lasts, its echo's tail included: the last note's end, its release, and
  /// three repeats.
  public var duration: Double {
    var end = 0.0
    for voice in voices {
      for note in voice.notes {
        end = max(end, note.start + note.length + voice.release)
      }
    }
    if let echo { end += echo.delay * 3 }
    return end
  }

  /// What is wrong with it, in words an agent can fix; empty when it can be played.
  public var problems: [String] {
    var problems: [String] = []
    if AlertSoundRules.name(name) == nil { problems.append("name is empty") }
    if voices.isEmpty { problems.append("voices is empty") }
    if voices.count > Self.maximumVoices {
      problems.append("\(voices.count) voices: \(Self.maximumVoices) at most")
    }
    for (index, voice) in voices.enumerated() {
      let at = "voices[\(index)]"
      Self.check(voice.gain, in: Self.unitRange, "\(at).gain", into: &problems)
      Self.check(voice.attack, in: Self.attackRange, "\(at).attack", into: &problems)
      Self.check(voice.decay, in: Self.decayRange, "\(at).decay", into: &problems)
      Self.check(voice.sustain, in: Self.unitRange, "\(at).sustain", into: &problems)
      Self.check(voice.release, in: Self.releaseRange, "\(at).release", into: &problems)
      if let cutoff = voice.cutoff {
        Self.check(cutoff, in: Self.cutoffRange, "\(at).cutoff", into: &problems)
      }
      if voice.notes.isEmpty { problems.append("\(at).notes is empty") }
      if voice.notes.count > Self.maximumNotes {
        problems.append("\(at): \(voice.notes.count) notes, \(Self.maximumNotes) at most")
      }
      for (position, note) in voice.notes.enumerated() {
        let place = "\(at).notes[\(position)]"
        if !note.start.isFinite || note.start < 0 { problems.append("\(place).start is negative") }
        Self.check(note.length, in: Self.lengthRange, "\(place).length", into: &problems)
        if let frequency = Self.frequency(of: note.pitch) {
          if !Self.frequencyRange.contains(frequency) {
            problems.append("\(place).pitch \(note.pitch) is out of hearing range")
          }
        } else {
          problems.append("\(place).pitch \"\(note.pitch)\" is not a note such as E5, F#3 or Bb4")
        }
      }
    }
    if let echo {
      Self.check(echo.delay, in: Self.delayRange, "echo.delay", into: &problems)
      Self.check(echo.feedback, in: Self.feedbackRange, "echo.feedback", into: &problems)
      Self.check(echo.mix, in: Self.unitRange, "echo.mix", into: &problems)
    }
    if problems.isEmpty, duration > Self.maximumDuration {
      problems.append(
        "the sound lasts \(String(format: "%.2f", duration)) s with its releases and echo: "
          + "\(Int(Self.maximumDuration)) s at most")
    }
    return problems
  }

  private static func check(
    _ value: Double, in range: ClosedRange<Double>, _ name: String, into problems: inout [String]
  ) {
    guard !(value.isFinite && range.contains(value)) else { return }
    problems.append(
      "\(name) is \(value): it must be from \(range.lowerBound) to \(range.upperBound)")
  }

  /// The frequency of a note name, in Hz, A4 = 440; `nil` when it is not one.
  public static func frequency(of pitch: String) -> Double? {
    let characters = Array(pitch.trimmingCharacters(in: .whitespaces))
    guard characters.count >= 2, characters.count <= 4 else { return nil }
    let semitones: [Character: Int] = ["C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2]
    guard let base = semitones[Character(characters[0].uppercased())] else { return nil }
    var index = 1
    var offset = base
    if characters[index] == "#" || characters[index] == "♯" {
      offset += 1
      index += 1
    } else if characters[index] == "b" || characters[index] == "♭" {
      offset -= 1
      index += 1
    }
    guard index < characters.count,
      let octave = Int(String(characters[index...])), (0...8).contains(octave)
    else { return nil }
    let fromA4 = Double(offset + (octave - 4) * 12)
    return 440 * pow(2, fromA4 / 12)
  }

  // MARK: - Reading

  /// The recipe an answer gives, or what is wrong with it.
  public static func decode(_ data: Data) -> Result<AlertSoundRecipe, AlertSoundRecipeProblem> {
    guard data.count <= maximumSize else { return .failure(.tooLarge) }
    let recipe: AlertSoundRecipe
    do {
      recipe = try JSONDecoder().decode(AlertSoundRecipe.self, from: data)
    } catch {
      return .failure(.notARecipe)
    }
    let problems = recipe.problems
    guard problems.isEmpty else { return .failure(.invalid(problems)) }
    return .success(recipe)
  }

  /// No recipe of the bounds above weighs more.
  public static let maximumSize = 64 * 1024

  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self)) ?? Data()
  }
}

/// Why an answer is not a recipe that can be played.
public enum AlertSoundRecipeProblem: Error, Hashable, Sendable {
  case tooLarge
  case notARecipe
  case invalid([String])

  /// What the agent is told, the second time.
  public var details: [String] {
    switch self {
    case .tooLarge: ["the answer is larger than \(AlertSoundRecipe.maximumSize) bytes"]
    case .notARecipe: ["the answer is not a JSON object of the schema"]
    case .invalid(let problems): problems
    }
  }
}
