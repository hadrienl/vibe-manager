import Foundation

/// Plays a recipe into samples (#393): mono, 44.1 kHz, brought to −1 dBFS. Plain arithmetic, with
/// no audio engine: the same recipe gives the same samples, on any Mac and in the tests.
public enum AlertSoundSynthesizer {
  public static let sampleRate = 44_100
  /// −1 dBFS: loud enough to be heard, never clipped.
  public static let peak: Float = 0.891
  /// The last moment of the sound fades to silence: no click at its end.
  static let fadeOut = 0.005

  public static func render(_ recipe: AlertSoundRecipe) -> [Float] {
    let rate = Double(sampleRate)
    let count = max(
      1, Int((min(recipe.duration, AlertSoundRecipe.maximumDuration) * rate).rounded(.up)))
    var mix = [Float](repeating: 0, count: count)
    for voice in recipe.voices {
      var line = [Float](repeating: 0, count: count)
      // The noise is the same each time: a recipe always sounds the same.
      var seed: UInt32 = 0x9E37_79B9
      for note in voice.notes {
        guard let frequency = AlertSoundRecipe.frequency(of: note.pitch) else { continue }
        let first = max(0, Int(note.start * rate))
        let held = note.length
        let end = min(count, Int((note.start + held + voice.release) * rate) + 1)
        guard first < end else { continue }
        var phase = 0.0
        let step = frequency / rate
        for index in first..<end {
          let time = Double(index - first) / rate
          let level = envelope(at: time, held: held, voice: voice)
          let value: Double
          switch voice.wave {
          case .sine: value = sin(2 * .pi * phase)
          case .triangle: value = 1 - 4 * abs(phase - 0.5)
          case .square: value = phase < 0.5 ? 1 : -1
          case .sawtooth: value = 2 * phase - 1
          case .noise:
            seed = seed &* 1_664_525 &+ 1_013_904_223
            value = Double(seed) / Double(UInt32.max) * 2 - 1
          }
          line[index] += Float(value * level * voice.gain)
          phase += step
          if phase >= 1 { phase -= floor(phase) }
        }
      }
      if let cutoff = voice.cutoff { lowPass(&line, cutoff: cutoff) }
      for index in 0..<count { mix[index] += line[index] }
    }
    if let echo = recipe.echo { applyEcho(&mix, echo) }
    normalize(&mix)
    let fade = min(count, Int(fadeOut * rate))
    for offset in 0..<fade {
      mix[count - 1 - offset] *= Float(offset) / Float(fade)
    }
    return mix
  }

  /// The level of a note at `time` from its start: up during the attack, down to the sustain
  /// during the decay, held, then down to silence during the release.
  static func envelope(at time: Double, held: Double, voice: AlertSoundRecipe.Voice) -> Double {
    let level: (Double) -> Double = { time in
      if time < voice.attack { return voice.attack > 0 ? time / voice.attack : 1 }
      let afterAttack = time - voice.attack
      if afterAttack < voice.decay {
        return 1 - (1 - voice.sustain) * (afterAttack / voice.decay)
      }
      return voice.sustain
    }
    if time <= held { return level(time) }
    guard voice.release > 0 else { return 0 }
    let released = time - held
    return max(0, level(held) * (1 - released / voice.release))
  }

  /// A one-pole low-pass filter.
  static func lowPass(_ samples: inout [Float], cutoff: Double) {
    let rc = 1 / (2 * .pi * cutoff)
    let dt = 1 / Double(sampleRate)
    let alpha = Float(dt / (rc + dt))
    var previous: Float = 0
    for index in samples.indices {
      previous += alpha * (samples[index] - previous)
      samples[index] = previous
    }
  }

  /// A feedback delay: each repeat comes back `feedback` as loud, `mix` beside the sound.
  static func applyEcho(_ samples: inout [Float], _ echo: AlertSoundRecipe.Echo) {
    let delay = max(1, Int(echo.delay * Double(sampleRate)))
    guard delay < samples.count else { return }
    var line = [Float](repeating: 0, count: samples.count)
    for index in delay..<samples.count {
      line[index] = samples[index - delay] + Float(echo.feedback) * line[index - delay]
    }
    for index in samples.indices {
      samples[index] += Float(echo.mix) * line[index]
    }
  }

  static func normalize(_ samples: inout [Float]) {
    let loudest = samples.reduce(0) { max($0, abs($1)) }
    guard loudest > 0 else { return }
    let gain = peak / loudest
    for index in samples.indices { samples[index] *= gain }
  }
}

/// Samples to a WAV file and back (#393): what the library keeps, and what the notifications of
/// macOS play. 16-bit PCM, mono.
public enum AlertSoundWave {
  public static func encode(_ samples: [Float], sampleRate: Int = AlertSoundSynthesizer.sampleRate)
    -> Data
  {
    var data = Data()
    let byteCount = UInt32(samples.count * 2)
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + byteCount)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(byteCount)
    data.reserveCapacity(data.count + samples.count * 2)
    for sample in samples {
      let clamped = max(-1, min(1, sample))
      append(Int16((clamped * Float(Int16.max)).rounded()))
    }
    return data
  }

  /// The samples of a WAV this application wrote, with its rate; `nil` for any other file.
  public static func decode(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
    let bytes = [UInt8](data)
    guard bytes.count >= 44, Array(bytes[0..<4]) == Array("RIFF".utf8),
      Array(bytes[8..<12]) == Array("WAVE".utf8)
    else { return nil }
    func read16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    func read32(_ at: Int) -> UInt32 {
      UInt32(read16(at)) | UInt32(read16(at + 2)) << 16
    }
    var offset = 12
    var rate: Int?
    while offset + 8 <= bytes.count {
      let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
      let size = Int(read32(offset + 4))
      let body = offset + 8
      if id == "fmt " {
        guard size >= 16, body + 16 <= bytes.count, read16(body) == 1, read16(body + 2) == 1,
          read16(body + 14) == 16
        else { return nil }
        rate = Int(read32(body + 4))
      } else if id == "data", let rate {
        let end = min(bytes.count, body + size)
        var samples: [Float] = []
        samples.reserveCapacity((end - body) / 2)
        var at = body
        while at + 1 < end {
          samples.append(Float(Int16(bitPattern: read16(at))) / Float(Int16.max))
          at += 2
        }
        return (samples, rate)
      }
      offset = body + size + (size % 2)
    }
    return nil
  }

  /// The loudness of `count` slices of the samples, from 0 to 1: the shape a list draws.
  public static func outline(of samples: [Float], count: Int) -> [Float] {
    guard count > 0, !samples.isEmpty else { return [] }
    let loudest = max(samples.reduce(0) { max($0, abs($1)) }, .ulpOfOne)
    return (0..<count).map { slice in
      let start = slice * samples.count / count
      let end = max(start + 1, (slice + 1) * samples.count / count)
      var peak: Float = 0
      for index in start..<min(end, samples.count) { peak = max(peak, abs(samples[index])) }
      return peak / loudest
    }
  }
}
