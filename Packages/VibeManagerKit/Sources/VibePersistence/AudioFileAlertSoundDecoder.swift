import AVFoundation
import VibeApplication

/// Reads an audio file with the system's decoders (#393): AIFF, WAV, CAF, M4A, MP3… brought to one
/// channel of 32-bit samples, at the file's own rate.
public struct AudioFileAlertSoundDecoder: AlertSoundDecoding {
  public init() {
    // Nothing to keep: each file is opened when it is read.
  }

  public func decode(_ url: URL, maximumDuration: Double) throws(AlertSoundImportProblem)
    -> DecodedAlertSound
  {
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
      throw .unreadable
    }
    let format = file.processingFormat
    let rate = format.sampleRate
    guard rate > 0, file.length > 0, format.channelCount > 0 else { throw .unreadable }
    let duration = Double(file.length) / rate
    // Refused before it is read: a long recording is not decoded to be thrown away.
    guard duration <= maximumDuration + 0.05 else { throw .tooLong(duration) }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
    else { throw .unreadable }
    do {
      try file.read(into: buffer)
    } catch {
      throw .unreadable
    }
    guard let channels = buffer.floatChannelData else { throw .unreadable }
    let frames = Int(buffer.frameLength)
    let count = Int(format.channelCount)
    var samples = [Float](repeating: 0, count: frames)
    for channel in 0..<count {
      let data = channels[channel]
      for frame in 0..<frames { samples[frame] += data[frame] / Float(count) }
    }
    return DecodedAlertSound(samples: samples, sampleRate: Int(rate.rounded()))
  }
}
