@preconcurrency import AVFoundation
import Foundation
import VibeApplication

/// The microphone, through an audio engine, converted as it is heard to what Whisper reads:
/// mono, 16 kHz, 32-bit floats (#340). Nothing is written to disk.
@MainActor
public final class MicrophoneRecorder: AudioRecording {
  private let engine = AVAudioEngine()
  private let buffer = SampleBuffer()

  public init() {}

  public var access: MicrophoneAccess {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted
    case .notDetermined: .undetermined
    default: .denied
    }
  }

  public func requestAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  public func start(cancellingEcho: Bool) throws {
    buffer.reset()
    let input = engine.inputNode
    // The system's voice processing: echo cancellation, against what this Mac plays. Turned on
    // before the format is read — it changes it.
    if input.isVoiceProcessingEnabled != cancellingEcho {
      try? input.setVoiceProcessingEnabled(cancellingEcho)
    }
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(DictationTranscript.sampleRate),
        channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: format, to: target)
    else { throw RecordingError.noInput }
    input.installTap(
      onBus: 0, bufferSize: 4_096, format: format,
      block: Self.tap(into: buffer, with: converter, to: target))
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
  }

  public func takeSamples() -> [Float] {
    buffer.take()
  }

  public func stop() -> [Float] {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    return buffer.take()
  }

  /// The block the engine calls on its audio thread. Made outside the main actor: a closure written
  /// in a method of the main actor would inherit its isolation, and the check Swift 6 puts at its
  /// entry would stop the application on the first buffer.
  nonisolated private static func tap(
    into buffer: SampleBuffer, with converter: AVAudioConverter, to target: AVAudioFormat
  ) -> AVAudioNodeTapBlock {
    { incoming, _ in buffer.append(convert(incoming, with: converter, to: target)) }
  }

  /// `incoming` at the input's rate and channels, as mono samples at 16 kHz. Called on the audio
  /// thread, for each buffer, by the same converter: it keeps what it needs between them.
  nonisolated private static func convert(
    _ incoming: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat
  ) -> [Float] {
    let ratio = target.sampleRate / incoming.format.sampleRate
    let capacity = AVAudioFrameCount((Double(incoming.frameLength) * ratio).rounded(.up)) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      return []
    }
    nonisolated(unsafe) var given = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if given {
        status.pointee = .noDataNow
        return nil
      }
      given = true
      status.pointee = .haveData
      return incoming
    }
    guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
  }

  enum RecordingError: Error {
    /// No microphone, or one that gives no sound.
    case noInput
  }
}

/// What was heard so far, appended from the audio thread and taken from the main one.
private final class SampleBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Float] = []

  func reset() {
    lock.withLock { samples = [] }
  }

  func append(_ more: [Float]) {
    lock.withLock { samples.append(contentsOf: more) }
  }

  func take() -> [Float] {
    lock.withLock {
      defer { samples = [] }
      return samples
    }
  }
}
