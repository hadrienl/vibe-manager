import Foundation
import VibeApplication

/// What the avatar screen says (#41): the names of the expressions, why an agent cannot draw, and
/// why an avatar was not accepted — each problem in a sentence that says what to do.
public enum AvatarPresentation {
  public static func name(of expression: AvatarExpression) -> LocalizedStringResource {
    switch expression {
    case .neutral:
      return LocalizedStringResource("Neutral", bundle: .module, comment: "An avatar expression.")
    case .mouthHalfOpen:
      return LocalizedStringResource(
        "Mouth half open", bundle: .module, comment: "An avatar expression.")
    case .mouthOpen:
      return LocalizedStringResource(
        "Mouth wide open", bundle: .module, comment: "An avatar expression.")
    case .mouthRound:
      return LocalizedStringResource(
        "Mouth in an O", bundle: .module, comment: "An avatar expression.")
    case .eyesHalfClosed:
      return LocalizedStringResource(
        "Eyes half closed", bundle: .module, comment: "An avatar expression.")
    case .eyesClosed:
      return LocalizedStringResource(
        "Eyes closed", bundle: .module, comment: "An avatar expression.")
    case .pleased:
      return LocalizedStringResource("Pleased", bundle: .module, comment: "An avatar expression.")
    case .surprised:
      return LocalizedStringResource(
        "Surprised", bundle: .module, comment: "An avatar expression.")
    case .thinking:
      return LocalizedStringResource("Thinking", bundle: .module, comment: "An avatar expression.")
    case .worried:
      return LocalizedStringResource("Worried", bundle: .module, comment: "An avatar expression.")
    }
  }

  static func name(_ expression: AvatarExpression) -> String {
    String(localized: name(of: expression))
  }

  public static func reason(_ unavailability: AvatarGenerationUnavailability)
    -> LocalizedStringResource
  {
    switch unavailability {
    case .notCapable:
      return LocalizedStringResource(
        "does not produce images", bundle: .module,
        comment: "Why an agent cannot draw an avatar: after its name, as in 'Claude Code — …'.")
    case .missing:
      return LocalizedStringResource(
        "not installed", bundle: .module,
        comment: "Why an agent cannot draw an avatar: after its name.")
    case .outdated:
      return LocalizedStringResource(
        "too old: update it", bundle: .module,
        comment: "Why an agent cannot draw an avatar: after its name.")
    case .signedOut:
      return LocalizedStringResource(
        "signed out: sign in from a terminal", bundle: .module,
        comment: "Why an agent cannot draw an avatar: after its name.")
    }
  }

  public static func message(for problem: AvatarStudioModel.Problem) -> LocalizedStringResource {
    switch problem {
    case .generation(let error):
      return message(for: error)
    case .archive(let problem):
      return message(for: problem)
    case .storedAvatar(let missing) where !missing.isEmpty:
      let names = missing.map(name).formatted(.list(type: .and))
      return LocalizedStringResource(
        "Your avatar lacks expressions this version shows (\(names)): the default one is shown until they are generated.",
        bundle: .module, comment: "The kept avatar is incomplete.")
    case .storedAvatar:
      return LocalizedStringResource(
        "Your avatar could not be read: the default one is shown. Make or import it again.",
        bundle: .module, comment: "The kept avatar cannot be read.")
    case .saving:
      return LocalizedStringResource(
        "The avatar could not be saved: the previous one is kept.", bundle: .module,
        comment: "Writing the avatar failed.")
    case .exporting:
      return LocalizedStringResource(
        "The avatar could not be exported.", bundle: .module, comment: "Exporting failed.")
    }
  }

  static func message(for error: AvatarGenerationError) -> LocalizedStringResource {
    switch error {
    case .unavailable(let unavailability):
      return LocalizedStringResource(
        "This agent cannot draw now: \(String(localized: reason(unavailability))).",
        bundle: .module, comment: "A generation could not start.")
    case .timedOut:
      return LocalizedStringResource(
        "The agent took too long: nothing was changed. Try again.", bundle: .module,
        comment: "A generation timed out.")
    case .noImage:
      return LocalizedStringResource(
        "The agent finished without producing an image. Try again, or describe the avatar differently.",
        bundle: .module, comment: "A generation gave no image.")
    case .failed:
      return LocalizedStringResource(
        "The agent could not draw the avatar: nothing was changed. Try again.", bundle: .module,
        comment: "A generation failed.")
    case .rejected(let problem):
      return message(for: problem)
    }
  }

  static func message(for problem: AvatarProblem) -> LocalizedStringResource {
    switch problem {
    case .unreadableImage:
      return LocalizedStringResource(
        "The image received cannot be read.", bundle: .module, comment: "An avatar problem.")
    case .imageTooLarge:
      return LocalizedStringResource(
        "The image received is too large.", bundle: .module, comment: "An avatar problem.")
    case .wrongGrid(let columns, let rows, let width, let height):
      return LocalizedStringResource(
        "The sheet received is not a grid of \(columns) × \(rows) expressions (\(width) × \(height) pixels). Try again.",
        bundle: .module, comment: "An avatar problem.")
    case .cellTooSmall:
      return LocalizedStringResource(
        "The expressions of the sheet received are too small.", bundle: .module,
        comment: "An avatar problem.")
    case .emptyCell(let expression):
      return LocalizedStringResource(
        "The expression “\(name(expression))” is empty.", bundle: .module,
        comment: "An avatar problem.")
    case .cutCell(let expression):
      return LocalizedStringResource(
        "The expression “\(name(expression))” is cut by the edge of its image.", bundle: .module,
        comment: "An avatar problem.")
    case .inconsistentSize(let expression):
      return LocalizedStringResource(
        "The character of “\(name(expression))” is not the size of the others.", bundle: .module,
        comment: "An avatar problem.")
    case .backgroundNotRemoved(let expression):
      return LocalizedStringResource(
        "The background of “\(name(expression))” could not be removed.", bundle: .module,
        comment: "An avatar problem.")
    case .archiveUnreadable:
      return LocalizedStringResource(
        "This file is not a readable zip archive.", bundle: .module, comment: "An avatar problem.")
    case .archiveTooLarge:
      return LocalizedStringResource(
        "This archive is too large, or holds too many files, to be an avatar.", bundle: .module,
        comment: "An avatar problem.")
    case .archiveUnsafeEntry(let entry):
      return LocalizedStringResource(
        "The archive holds an entry that is not a plain file of its folder (\(entry)): it was not imported.",
        bundle: .module, comment: "An avatar problem.")
    case .archiveEncrypted:
      return LocalizedStringResource(
        "The archive is encrypted.", bundle: .module, comment: "An avatar problem.")
    case .archiveFromNewerVersion:
      return LocalizedStringResource(
        "This avatar comes from a later version of Vibe Manager.", bundle: .module,
        comment: "An avatar problem.")
    case .archiveHasNoImage:
      return LocalizedStringResource(
        "The archive holds no image named after an expression (neutral.png, pleased.png…).",
        bundle: .module, comment: "An avatar problem.")
    case .imageNotSquare(let expression):
      return LocalizedStringResource(
        "The image of “\(name(expression))” is not square.", bundle: .module,
        comment: "An avatar problem.")
    case .imageTooSmall(let expression):
      return LocalizedStringResource(
        "The image of “\(name(expression))” is too small: 128 pixels at least.", bundle: .module,
        comment: "An avatar problem.")
    case .imagesOfDifferentSizes(let expression):
      return LocalizedStringResource(
        "The image of “\(name(expression))” is not the size of the others.", bundle: .module,
        comment: "An avatar problem.")
    }
  }
}
