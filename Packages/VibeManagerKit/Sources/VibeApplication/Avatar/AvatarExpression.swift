/// One image of the avatar that presents the requests in the floating panel (#41).
///
/// The list is the animation's: every expression `AvatarAnimation` can show is here, and nothing
/// else. The prompt that generates an avatar asks for exactly these, in this order, so the two
/// cannot drift apart — the tests check both ways.
public enum AvatarExpression: String, CaseIterable, Codable, Hashable, Sendable {
  case neutral
  case mouthHalfOpen
  case mouthOpen
  case mouthRound
  case eyesHalfClosed
  case eyesClosed
  case pleased
  case surprised
  case thinking
  case worried

  /// The file an avatar keeps this expression in: `neutral.png`.
  public var fileName: String { rawValue + ".png" }

  /// What the image generator is told to draw, in English: the instructions are precise because
  /// a loose one drifts — "eyes closed" once came back as a squinting laugh.
  public var drawingInstruction: String {
    switch self {
    case .neutral:
      return "neutral, calm, eyes open, mouth closed"
    case .mouthHalfOpen:
      return "speaking: mouth half open, eyes open"
    case .mouthOpen:
      return "speaking: mouth wide open, eyes open"
    case .mouthRound:
      return "speaking: mouth in a small round O shape, as when saying \"oh\", eyes open"
    case .eyesHalfClosed:
      return "blinking: both eyes half closed, mouth closed, calm"
    case .eyesClosed:
      return "blinking: both eyes fully closed, mouth closed, calm, not smiling"
    case .pleased:
      return "pleased and satisfied: warm smile, eyes open"
    case .surprised:
      return "surprised and alert: eyes wide open, eyebrows raised, small open mouth"
    case .thinking:
      return "thinking, waiting: eyes looking up to one side, mouth closed and slightly pursed"
    case .worried:
      return "worried, something went wrong: eyebrows tilted, small frown"
    }
  }
}
