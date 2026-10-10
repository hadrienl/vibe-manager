import Foundation
import Testing

@testable import VibeApplication

@Suite("What dictation does with what it heard (#340)")
struct DictationTranscriptTests {
  /// `seconds` of a tone of `amplitude`, as the microphone gives it.
  private static func tone(amplitude: Float, seconds: Double) -> [Float] {
    let count = Int(Double(DictationTranscript.sampleRate) * seconds)
    return (0..<count).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
  }

  @Test("A silence, or the hum of a quiet room, is not speech; a voice is")
  func speechDetection() {
    #expect(!DictationTranscript.containsSpeech([]))
    #expect(!DictationTranscript.containsSpeech([Float](repeating: 0, count: 32_000)))
    #expect(!DictationTranscript.containsSpeech(Self.tone(amplitude: 0.005, seconds: 2)))
    #expect(DictationTranscript.containsSpeech(Self.tone(amplitude: 0.2, seconds: 2)))
    // A word between two silences is enough.
    let word = [Float](repeating: 0, count: 16_000) + Self.tone(amplitude: 0.2, seconds: 0.3)
      + [Float](repeating: 0, count: 16_000)
    #expect(DictationTranscript.containsSpeech(word))
    // Shorter than a tenth of a second: a click, not a word.
    #expect(!DictationTranscript.containsSpeech(Self.tone(amplitude: 0.5, seconds: 0.05)))
  }

  @Test("The credits Whisper makes up over a pause are taken out, whatever their case")
  func hallucinations() {
    #expect(DictationTranscript.cleaned("Sous-titres réalisés par la communauté d'Amara.org") == "")
    #expect(DictationTranscript.cleaned(" SOUS-TITRES RÉALISÉS PAR LA COMMUNAUTÉ D'AMARA.ORG. ") == "")
    #expect(
      DictationTranscript.cleaned("Ajoute un test. Merci d'avoir regardé cette vidéo")
        == "Ajoute un test.")
    #expect(DictationTranscript.cleaned("  Fix the build  ") == "Fix the build")
    #expect(DictationTranscript.cleaned(" … ") == "")
    // Said within a sentence, the words are the user's.
    #expect(
      DictationTranscript.cleaned("Add a footer that says thanks for watching")
        == "Add a footer that says thanks for watching")
  }

  @Test("Dictated text is spaced from the words it lands between, not from spaces or punctuation")
  func spacing() {
    #expect(DictationTranscript.spaced("ok", after: nil, before: nil) == "ok")
    #expect(DictationTranscript.spaced("ok", after: "a", before: nil) == " ok")
    #expect(DictationTranscript.spaced("ok", after: " ", before: "b") == "ok ")
    #expect(DictationTranscript.spaced("ok", after: "\n", before: ".") == "ok")
  }

  @Test("The prompt names the project and its branch last, where Whisper reads it, once each")
  func prompt() {
    let prompt = DictationTranscript.prompt(
      projectName: "vibe-manager", branch: "feat/340-voice-dictation",
      fileNames: ["Package.swift", "README.md", "README.md"])
    #expect(prompt.hasSuffix("Package.swift, README.md, feat/340-voice-dictation, vibe-manager"))
    #expect(prompt.contains("pull request"))
    #expect(prompt.components(separatedBy: "README.md").count == 2)
  }

  @Test("A long prompt loses its first words, never the project's")
  func longPrompt() {
    let files = (0..<200).map { "SomeRatherLongFileName\($0).swift" }
    let prompt = DictationTranscript.prompt(projectName: "atlas", branch: "main", fileNames: files)
    #expect(prompt.count <= 200)
    #expect(prompt.hasSuffix("SomeRatherLongFileName4.swift, main, atlas"))
    // Five files at most: the rest of the folder says nothing more.
    #expect(!prompt.contains("SomeRatherLongFileName5.swift"))
  }
}

@Suite("Where a sentence of the discussion begins and ends (#357)")
struct UtteranceDetectorTests {
  private static let silence = [Float](repeating: 0.001, count: 1_600)
  private static func voice(_ amplitude: Float) -> [Float] {
    (0..<1_600).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
  }

  @Test("A voice begins a sentence; a pause of 1.2 s ends it, its start kept")
  func sentence() {
    var detector = UtteranceDetector()
    var events: [UtteranceDetector.Event] = []
    for _ in 0..<5 { events += detector.feed(Self.silence) }
    #expect(events.isEmpty)
    for _ in 0..<8 { events += detector.feed(Self.voice(0.2)) }
    #expect(events == [.speechStarted])
    #expect(detector.isHearingSpeech)
    for _ in 0..<(UtteranceDetector.pauseFrames - 1) { events += detector.feed(Self.silence) }
    #expect(events.count == 1)
    events += detector.feed(Self.silence)
    guard case .utterance(let samples) = events.last else {
      Issue.record("No sentence ended")
      return
    }
    // Its eight tenths of voice, the tenths before it, and the first tenth of the pause.
    #expect(samples.count >= 9 * 1_600)
    #expect(!detector.isHearingSpeech)
  }

  @Test("A click, two tenths of a second, is no sentence")
  func click() {
    var detector = UtteranceDetector()
    var events: [UtteranceDetector.Event] = []
    events += detector.feed(Self.voice(0.3) + Self.voice(0.3))
    for _ in 0..<20 { events += detector.feed(Self.silence) }
    #expect(events.isEmpty)
  }

  @Test("While the Mac speaks, only a voice well above its echo cuts in")
  func overTheVoice() {
    var detector = UtteranceDetector()
    var events: [UtteranceDetector.Event] = []
    // The voice's echo, even in bursts, is not a sentence.
    for _ in 0..<5 { events += detector.feed(Self.voice(0.05), whileSpeaking: true) }
    for _ in 0..<4 { events += detector.feed(Self.voice(0.3), whileSpeaking: true) }
    #expect(events.isEmpty)
    // Half a second of a loud voice is.
    events += detector.feed(Self.voice(0.3), whileSpeaking: true)
    #expect(events == [.speechStarted])
  }

  @Test("A loud room is learnt, not taken for a voice: a sentence over it still ends")
  func loudRoom() {
    var detector = UtteranceDetector()
    var events: [UtteranceDetector.Event] = []
    // A fan at 0.03, louder than the threshold of a quiet room.
    for _ in 0..<60 { events += detector.feed(Self.voice(0.03)) }
    #expect(!events.contains(.speechStarted) || events.contains { if case .utterance = $0 { true } else { false } })
    events = []
    for _ in 0..<8 { events += detector.feed(Self.voice(0.3)) }
    #expect(events == [.speechStarted])
    for _ in 0..<UtteranceDetector.pauseFrames { events += detector.feed(Self.voice(0.03)) }
    #expect(events.count == 2)
  }

  @Test("A sentence under way when the discussion ends is given back; a breath is not")
  func flush() {
    var detector = UtteranceDetector()
    _ = detector.feed(Self.silence)
    for _ in 0..<6 { _ = detector.feed(Self.voice(0.2)) }
    #expect((detector.flush()?.count ?? 0) >= 6 * 1_600)
    #expect(detector.flush() == nil)
    #expect(!detector.isHearingSpeech)
  }

  @Test("« Stop » and « arrête » stop the agent; a sentence that contains them does not")
  func stopWords() {
    #expect(UtteranceDetector.isStop("Stop."))
    #expect(UtteranceDetector.isStop(" Arrête ! "))
    #expect(!UtteranceDetector.isStop("Arrête le serveur de dev."))
  }
}
