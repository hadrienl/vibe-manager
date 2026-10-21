import Foundation
import SwiftUI
import VibeApplication

/// What the screens say about the alert sounds (#393).
@MainActor
enum AlertSoundPresentation {
  /// What the user calls a sound.
  static func name(of choice: AlertSoundChoice, in sounds: AlertSoundLibraryModel) -> String {
    switch choice {
    case .systemDefault:
      String(
        localized: LocalizedStringResource(
          "System Default", bundle: .module,
          comment: "The alert sound chosen in System Settings, as an alert sound of Vibe Manager."))
    case .none:
      String(
        localized: LocalizedStringResource(
          "None", bundle: .module, comment: "No alert sound: the notification stays, silent."))
    case .bundled(let key):
      BundledAlertSound(rawValue: key).map(name(of:)) ?? key
    case .macOS(let name):
      name
    case .custom(let id):
      sounds.entry(id).map { DisplaySafeText.visible($0.name) }
        ?? String(
          localized: LocalizedStringResource(
            "Missing sound", bundle: .module,
            comment: "A sound of the user's own that was deleted, or cannot be found."))
    }
  }

  static func name(of sound: BundledAlertSound) -> String {
    switch sound {
    case .chime:
      String(
        localized: LocalizedStringResource(
          "Chime", bundle: .module, comment: "An alert sound shipped with the application."))
    case .drop:
      String(
        localized: LocalizedStringResource(
          "Drop", bundle: .module,
          comment: "An alert sound shipped with the application: a water drop."))
    case .signal:
      String(
        localized: LocalizedStringResource(
          "Signal", bundle: .module,
          comment: "An alert sound shipped with the application: three short beeps."))
    case .tick:
      String(
        localized: LocalizedStringResource(
          "Tick", bundle: .module,
          comment: "An alert sound shipped with the application: a short click."))
    }
  }

  /// Where a sound comes from, under its name.
  static func origin(of choice: AlertSoundChoice, in sounds: AlertSoundLibraryModel) -> String {
    switch choice {
    case .systemDefault:
      return String(
        localized: LocalizedStringResource(
          "The alert sound of macOS", bundle: .module,
          comment: "Under “System Default” in the list of sounds."))
    case .none:
      return String(
        localized: LocalizedStringResource(
          "The notification stays, without a sound", bundle: .module,
          comment: "Under “None” in the list of sounds."))
    case .bundled:
      return String(
        localized: LocalizedStringResource(
          "Shipped with Vibe Manager", bundle: .module,
          comment: "Where an alert sound comes from."))
    case .macOS:
      return String(
        localized: LocalizedStringResource(
          "A sound of macOS", bundle: .module, comment: "Where an alert sound comes from."))
    case .custom(let id):
      guard let entry = sounds.entry(id) else { return "" }
      switch entry.origin {
      case .imported:
        return String(
          localized: LocalizedStringResource(
            "Imported", bundle: .module, comment: "Where an alert sound comes from: a file."))
      case .composed(let agent):
        return String(
          localized: LocalizedStringResource(
            "Composed with \(agentName(agent, in: sounds))", bundle: .module,
            comment: "Where an alert sound comes from: the agent that composed it."))
      }
    }
  }

  /// The name an agent is shown under.
  static func agentName(_ provider: String, in sounds: AlertSoundLibraryModel) -> String {
    if let option = sounds.options.first(where: { $0.id.rawValue == provider }) {
      return option.descriptor.displayName
    }
    switch provider {
    case "claude-code": return "Claude Code"
    case "codex": return "Codex"
    default: return provider.isEmpty ? "?" : provider.prefix(1).uppercased() + provider.dropFirst()
    }
  }

  /// A duration as the list says it: "1.2 s".
  static func duration(_ seconds: Double, locale: Locale) -> String {
    Measurement(value: seconds, unit: UnitDuration.seconds).formatted(
      .measurement(
        width: .abbreviated, usage: .asProvided,
        numberFormatStyle: .number.precision(.fractionLength(1))
      ).locale(locale))
  }

  static func startAnnouncement(
    of job: AlertSoundLibraryModel.Job, in sounds: AlertSoundLibraryModel
  ) -> LocalizedStringResource {
    let agent = agentName(job.provider.rawValue, in: sounds)
    if job.target != nil {
      return LocalizedStringResource(
        "\(agent) is changing the sound.", bundle: .module,
        comment: "Said when an agent starts changing a sound of the user's own.")
    }
    return LocalizedStringResource(
      "\(agent) is composing the sound. It takes under a minute.", bundle: .module,
      comment: "Said when an agent starts composing an alert sound.")
  }

  /// What went wrong, in a sentence.
  static func message(for problem: AlertSoundLibraryModel.Problem) -> LocalizedStringResource {
    switch problem {
    case .importing(.unreadable, let file):
      LocalizedStringResource(
        "“\(file)” cannot be read as a sound. Choose an AIFF, WAV, CAF, M4A or MP3 file.",
        bundle: .module, comment: "An audio file refused on import.")
    case .importing(.tooLong(let seconds), let file):
      LocalizedStringResource(
        "“\(file)” lasts \(Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))). An alert sound lasts 30 seconds at most: shorten it in an audio editor, then import it again.",
        bundle: .module, comment: "An audio file refused on import: how long it lasts.")
    case .limitReached:
      LocalizedStringResource(
        "You keep \(AlertSoundRules.maximumCount) sounds already: delete one first.",
        bundle: .module, comment: "No new sound is added: the library is full.")
    case .generation(.unavailable(.signedOut)):
      LocalizedStringResource(
        "The agent is signed out: sign in to it in a terminal, then try again.", bundle: .module,
        comment: "A sound could not be composed.")
    case .generation(.unavailable):
      LocalizedStringResource(
        "The agent cannot run now: check it in Settings › Agents.", bundle: .module,
        comment: "A sound could not be composed.")
    case .generation(.timedOut):
      LocalizedStringResource(
        "The agent did not answer in time: nothing was changed. Try again.", bundle: .module,
        comment: "A sound could not be composed.")
    case .generation(.invalid):
      LocalizedStringResource(
        "The agent twice answered something that cannot be played: try describing the sound differently.",
        bundle: .module, comment: "A sound could not be composed.")
    case .generation(.failed):
      LocalizedStringResource(
        "The agent failed: nothing was changed. Try again.", bundle: .module,
        comment: "A sound could not be composed.")
    case .writing:
      LocalizedStringResource(
        "The sound could not be saved in the data folder.", bundle: .module,
        comment: "A sound could not be written to disk.")
    case .renaming:
      LocalizedStringResource(
        "The sound could not be renamed.", bundle: .module, comment: "A change that failed.")
    case .deleting:
      LocalizedStringResource(
        "The sound could not be deleted.", bundle: .module, comment: "A change that failed.")
    }
  }
}
