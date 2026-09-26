import AppKit
import SwiftUI
import VibeDomain

/// What a task status looks like: its words, its symbol and its colour (#80).
///
/// The symbol sets each status apart by its shape, so that the colour is never the only thing
/// telling two columns apart. Orange is left out on purpose: it already means "the agent waits for
/// you" (#45), and a column in orange would read as a column of sessions asking for an answer.
extension SessionTaskStatus {
  public var label: LocalizedStringResource {
    switch self {
    case .todo:
      return LocalizedStringResource(
        "To Do", bundle: .module, comment: "A task status: the session is planned, not started.")
    case .doing:
      return LocalizedStringResource(
        "In Progress", bundle: .module, comment: "A task status: the session is being worked on.")
    case .waiting:
      return LocalizedStringResource(
        "Waiting", bundle: .module,
        comment: "A task status: the session waits on something else, a review or a build.")
    case .done:
      return LocalizedStringResource(
        "Done", bundle: .module, comment: "A task status: the session's work is finished.")
    case .archived:
      return LocalizedStringResource(
        "Archived", bundle: .module, comment: "A task status: the session is archived.")
    }
  }

  /// The command that moves a session to this status, in a menu or a swipe button.
  public var moveTitle: LocalizedStringResource {
    switch self {
    case .todo:
      return LocalizedStringResource(
        "Move to To Do", bundle: .module, comment: "Changes a session's task status.")
    case .doing:
      return LocalizedStringResource(
        "Move to In Progress", bundle: .module, comment: "Changes a session's task status.")
    case .waiting:
      return LocalizedStringResource(
        "Move to Waiting", bundle: .module, comment: "Changes a session's task status.")
    case .done:
      return LocalizedStringResource(
        "Move to Done", bundle: .module, comment: "Changes a session's task status.")
    case .archived:
      return LocalizedStringResource(
        "Archive…", bundle: .module, comment: "Changes a session's task status.")
    }
  }

  /// The word on a swipe button, which has room for one.
  public var buttonTitle: LocalizedStringResource {
    self == .archived
      ? LocalizedStringResource(
        "Archive", bundle: .module, comment: "A swipe button that archives a session.")
      : label
  }

  public var symbolName: String {
    switch self {
    case .todo: return "circle.dashed"
    case .doing: return "circle.lefthalf.filled"
    case .waiting: return "pause.circle"
    case .done: return "checkmark.circle.fill"
    case .archived: return "archivebox"
    }
  }

  /// Solid enough to carry white text in both appearances: the swipe buttons are filled with it.
  public var tint: Color {
    Color(nsColor: nsTint)
  }

  var nsTint: NSColor {
    switch self {
    case .todo:
      // Slate rather than grey, so that To Do is not mistaken for Archived.
      return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.49, green: 0.53, blue: 0.60, alpha: 1)
          : NSColor(srgbRed: 0.42, green: 0.46, blue: 0.53, alpha: 1)
      }
    case .doing: return .systemBlue
    case .waiting: return .systemPurple
    case .done:
      // The system green is too light under white text in the light appearance.
      return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.14, green: 0.57, blue: 0.25, alpha: 1)
          : NSColor(srgbRed: 0.12, green: 0.54, blue: 0.23, alpha: 1)
      }
    case .archived: return .systemGray
    }
  }
}
