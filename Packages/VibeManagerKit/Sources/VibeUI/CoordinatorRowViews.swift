import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// What a coordinator's row says of its children (#352): how many, how many run, and the most
/// urgent — one waiting for the user, or the coordinator calling them.
///
/// Once there are children, it is also what folds them away (#387): a capsule with an arrow, so
/// that no chevron sets the coordinator's badge apart from the sessions around it. A click
/// anywhere else on the row selects it, and only selects it.
struct CoordinatorRowSummary: View {
  let model: AppModel
  let sessionID: SessionID
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let summary = model.summary(ofCoordinator: sessionID)
    if summary.count > 0 {
      toggle(summary)
    } else {
      label(summary)
        .instantTooltip(callTooltip ?? Text(verbatim: ""))
    }
  }

  private func toggle(_ summary: CoordinatorSummary) -> some View {
    let isExpanded = model.isExpanded(coordinator: sessionID)
    let action =
      isExpanded
      ? Text("Hide Children", bundle: .module, comment: "Folds a coordinator session's children.")
      : Text(
        "Show Children", bundle: .module, comment: "Unfolds a coordinator session's children.")
    return Button {
      withAnimation(reduceMotion ? nil : .fold) {
        model.setExpanded(!isExpanded, coordinator: sessionID)
      }
    } label: {
      HStack(spacing: 4) {
        label(summary)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.leading, Self.inset)
      .padding(.trailing, Self.inset + 2)
      .padding(.vertical, 1)
      // Seen without the pointer over it, so that it reads as a control before it is clicked.
      .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.14 : 0.07)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    // Its words in line with the row's other lines; the capsule reaches out into the gap.
    .padding(.leading, -Self.inset)
    .onHover { isHovering = $0 }
    .instantTooltip(callTooltip ?? action)
    .accessibilityLabel(action)
    .accessibilityValue(
      isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module))
  }

  /// Between the capsule's edge and its words.
  private static let inset: CGFloat = 5

  private var callTooltip: Text? {
    model.coordination.calls[sessionID].map { Text(verbatim: DisplaySafeText.visible($0)) }
  }

  private func label(_ summary: CoordinatorSummary) -> some View {
    let isCalling = model.isCallingUser(sessionID)
    return HStack(spacing: 4) {
      Image(systemName: "person.2")
        .accessibilityHidden(true)
      if isCalling {
        Text("Calling you", bundle: .module, comment: "A coordinator session asked for the user.")
          .foregroundStyle(.orange)
          .fontWeight(.semibold)
      } else if summary.needingUser > 0 {
        Text(
          "\(summary.needingUser) need you", bundle: .module,
          comment: "How many child sessions of a coordinator wait for the user."
        )
        .foregroundStyle(.orange)
        .fontWeight(.semibold)
      } else if summary.count == 0 {
        Text("Coordinator", bundle: .module, comment: "A session that coordinates child sessions.")
      } else {
        Text(
          "\(summary.count) children", bundle: .module,
          comment: "How many child sessions a coordinator has.")
        if summary.running > 0 {
          Text(verbatim: "·")
          Text(
            "\(summary.running) running", bundle: .module,
            comment: "How many child sessions of a coordinator have their agent running.")
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }
}
