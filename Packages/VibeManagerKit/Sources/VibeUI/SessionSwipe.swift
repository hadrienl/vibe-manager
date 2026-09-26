import CoreGraphics
import VibeDomain

/// The arithmetic of a row being swiped in the sidebar (#80), kept apart from the view so that it
/// can be tested without an event.
///
/// A swipe only ever reveals buttons. Nothing changes until one of them is clicked: the gesture
/// is too easy to make by accident on a trackpad to be the decision itself.
///
/// `translation` is how far the fingers or the pointer went, positive to the right. A swipe to the
/// right reveals, on the left of the row, the statuses before the current one; a swipe to the left
/// reveals the ones after it on the right. `offset` is what the row is moved by: it follows the
/// translation up to the buttons and the gap before them (#88), and gives way past them.
struct SessionSwipe: Equatable {
  /// One button's width at rest.
  static let buttonWidth: CGFloat = 76
  /// The space kept between the moved row and its buttons, so that the two don't read as one block.
  static let gap: CGFloat = 8
  /// What is always left of the row, however many buttons there are, so that it stays readable.
  static let reservedWidth: CGFloat = 72
  /// How far a side with no button still follows the gesture, to say there is nothing there.
  static let bareSideLimit: CGFloat = 36
  /// The share of the buttons' width past which letting go leaves them open.
  static let openingThreshold: CGFloat = 0.4

  let sessionID: SessionID
  /// Revealed on the left by a swipe to the right, nearest status first.
  let leading: [SessionTaskStatus]
  /// Revealed on the right by a swipe to the left, nearest status first.
  let trailing: [SessionTaskStatus]
  let availableWidth: CGFloat
  var translation: CGFloat = 0

  init(
    sessionID: SessionID,
    leading: [SessionTaskStatus],
    trailing: [SessionTaskStatus],
    availableWidth: CGFloat,
    translation: CGFloat = 0
  ) {
    self.sessionID = sessionID
    self.leading = leading
    self.trailing = trailing
    self.availableWidth = availableWidth
    self.translation = translation
  }

  /// How far a side opens: its buttons, and the gap between them and the row.
  var leadingWidth: CGFloat { width(for: leading.count) }
  var trailingWidth: CGFloat { width(for: trailing.count) }

  /// A side's buttons alone, as they are drawn once open.
  var leadingButtonsWidth: CGFloat { buttonsWidth(for: leading.count) }
  var trailingButtonsWidth: CGFloat { buttonsWidth(for: trailing.count) }

  /// How wide the buttons are drawn during the gesture: what the row uncovered, less the gap,
  /// which stays the same however far it goes.
  var revealedButtonsWidth: CGFloat { max(0, abs(offset) - Self.gap) }

  /// How far the row is moved: the translation, elastic past the buttons.
  var offset: CGFloat {
    let limit = translation > 0 ? leadingWidth : trailingWidth
    let distance = abs(translation)
    let sign: CGFloat = translation < 0 ? -1 : 1
    guard limit > 0 else {
      return sign * min(Self.bareSideLimit, distance * 0.25)
    }
    guard distance > limit else { return translation }
    return sign * (limit + (distance - limit) * 0.3)
  }

  /// The share of its buttons' width a side has uncovered, from 0 to 1.
  var progress: CGFloat {
    let limit = offset > 0 ? leadingWidth : trailingWidth
    guard limit > 0 else { return 0 }
    return min(1, abs(offset) / limit)
  }

  /// Which side's buttons are showing, if any.
  var revealedStatuses: [SessionTaskStatus] {
    if offset > 0 { return leading }
    if offset < 0 { return trailing }
    return []
  }

  /// Where the gesture comes to rest once let go: open on the buttons past the threshold, closed
  /// otherwise.
  var settledTranslation: CGFloat {
    if offset > 0, leadingWidth > 0, offset >= leadingWidth * Self.openingThreshold {
      return leadingWidth
    }
    if offset < 0, trailingWidth > 0, -offset >= trailingWidth * Self.openingThreshold {
      return -trailingWidth
    }
    return 0
  }

  var isOpen: Bool { translation != 0 }

  /// Opens a side at once, for the keyboard and VoiceOver's equivalent of the gesture.
  mutating func open(towardsNext: Bool) {
    translation = towardsNext ? -trailingWidth : leadingWidth
  }

  private func width(for count: Int) -> CGFloat {
    let buttons = buttonsWidth(for: count)
    return buttons > 0 ? buttons + Self.gap : 0
  }

  private func buttonsWidth(for count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    return min(
      CGFloat(count) * Self.buttonWidth,
      max(0, availableWidth - Self.reservedWidth - Self.gap))
  }
}
