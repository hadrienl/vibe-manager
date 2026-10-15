import SwiftUI
import VibeDomain

/// What a column of the sidebar draws: its sessions, and after a coordinator's children, the row
/// that shows or hides the done ones (#352).
enum SidebarItem: Identifiable {
  case session(WorkSession)
  case doneChildren(coordinator: SessionID, CoordinatorDoneChildren)

  var id: String {
    switch self {
    case .session(let session): session.id.rawValue.uuidString
    case .doneChildren(let coordinator, _): "done-" + coordinator.rawValue.uuidString
    }
  }

  var session: WorkSession? {
    if case .session(let session) = self { return session }
    return nil
  }

  /// `sessions` with a row after each coordinator's children — after the coordinator itself when
  /// none of them shows — wherever `done` counts some.
  static func items(
    of sessions: [WorkSession], done: (SessionID) -> CoordinatorDoneChildren?
  ) -> [SidebarItem] {
    var items: [SidebarItem] = []
    var family: SessionID?
    for session in sessions {
      let own = session.coordination?.coordinatorID ?? session.id
      if let family, family != own, let counted = done(family) {
        items.append(.doneChildren(coordinator: family, counted))
      }
      items.append(.session(session))
      family = own
    }
    if let family, let counted = done(family) {
      items.append(.doneChildren(coordinator: family, counted))
    }
    return items
  }
}

/// “Show Done Sessions (3)” under a coordinator's children, or “Hide Done Sessions” once shown.
struct DoneChildrenRow: View {
  let done: CoordinatorDoneChildren
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        Image(systemName: done.isShown ? "chevron.up" : "chevron.down")
          .font(.caption2.weight(.semibold))
        if done.isShown {
          Text("Hide Done Sessions", bundle: .module)
        } else {
          Text("Show Done Sessions (\(done.count))", bundle: .module)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.leading, SessionRow.childIndent)
    .padding(.vertical, 2)
    .accessibilityIdentifier("coordinator-done-children")
  }
}
