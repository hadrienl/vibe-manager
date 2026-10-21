import Foundation

/// The sound an audio file holds, brought to one channel.
public struct DecodedAlertSound: Hashable, Sendable {
  public let samples: [Float]
  public let sampleRate: Int

  public init(samples: [Float], sampleRate: Int) {
    self.samples = samples
    self.sampleRate = sampleRate
  }

  public var duration: Double {
    sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
  }
}

/// Why a file is not imported (#393). Nothing is added.
public enum AlertSoundImportProblem: Error, Hashable, Sendable {
  /// Not an audio file the Mac can read, or one without sound.
  case unreadable
  /// Longer than a notification plays: how long it lasts, in seconds.
  case tooLong(Double)
}

/// Reads audio files, done by `VibePersistence` with the system's decoders, behind this port so
/// that the rest never decodes a byte.
public protocol AlertSoundDecoding: Sendable {
  /// The sound of a file, refused without reading it all when it lasts longer than
  /// `maximumDuration`.
  func decode(_ url: URL, maximumDuration: Double) throws(AlertSoundImportProblem)
    -> DecodedAlertSound
}

/// A file made one of the user's own sounds: checked, brought to a WAV, added to the library
/// (#393). It is not put in use: the user chooses.
public struct ImportAlertSound: Sendable {
  public enum Failure: Error, Hashable, Sendable {
    case problem(AlertSoundImportProblem)
    case library(AlertSoundLibraryError)
  }

  private let decoder: any AlertSoundDecoding
  private let library: any AlertSoundLibrary
  private let now: @Sendable () -> Date

  public init(
    decoder: any AlertSoundDecoding, library: any AlertSoundLibrary,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.decoder = decoder
    self.library = library
    self.now = now
  }

  public func callAsFunction(_ url: URL) async throws(Failure) -> AlertSoundEntry {
    let sound: DecodedAlertSound
    do {
      sound = try decoder.decode(url, maximumDuration: AlertSoundRules.maximumImportedDuration)
    } catch {
      throw .problem(error)
    }
    guard !sound.samples.isEmpty, sound.sampleRate > 0 else { throw .problem(.unreadable) }
    guard sound.duration <= AlertSoundRules.maximumImportedDuration + 0.05 else {
      throw .problem(.tooLong(sound.duration))
    }
    let name =
      AlertSoundRules.name(url.deletingPathExtension().lastPathComponent)
      ?? url.lastPathComponent
    let entry = AlertSoundEntry(
      name: name, origin: .imported, addedAt: now(), duration: sound.duration)
    do {
      return try await library.add(
        entry, wave: AlertSoundWave.encode(sound.samples, sampleRate: sound.sampleRate))
    } catch let error as AlertSoundLibraryError {
      throw .library(error)
    } catch {
      throw .library(.storage)
    }
  }
}
