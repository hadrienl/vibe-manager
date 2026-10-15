import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// The chevron of a coordinator's row, which folds its children away (#352). It sits in the margin
/// left of the badge (#387), shown only once there are children to fold.
struct CoordinatorDisclosure: View {
  let model: AppModel
  let sessionID: SessionID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isExpanded = model.isExpanded(coordinator: sessionID)
    let hasChildren = !model.children(of: sessionID).isEmpty
    Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
        model.setExpanded(!isExpanded, coordinator: sessionID)
      }
    } label: {
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .foregroundStyle(.secondary)
        .frame(
          width: SessionRow.selectionInset + SessionRow.disclosureMargin,
          height: SessionRow.badgeSize
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(hasChildren ? 1 : 0)
    .disabled(!hasChildren)
    .instantTooltip(
      isExpanded
        ? Text("Hide Children", bundle: .module, comment: "Folds a coordinator session's children.")
        : Text(
          "Show Children", bundle: .module, comment: "Unfolds a coordinator session's children.")
    )
    // The row says it, and offers it as an action: the chevron is for the pointer.
    .accessibilityHidden(true)
  }
}

/// What a coordinator's row says of its children (#352): how many, how many run, and the most
/// urgent — one waiting for the user, or the coordinator calling them.
struct CoordinatorRowSummary: View {
  let model: AppModel
  let sessionID: SessionID

  var body: some View {
    let summary = model.summary(ofCoordinator: sessionID)
    let isCalling = model.isCallingUser(sessionID)
    HStack(spacing: 4) {
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
    .instantTooltip(
      model.coordination.calls[sessionID].map { Text(verbatim: DisplaySafeText.visible($0)) }
        ?? Text(verbatim: ""))
  }
}
