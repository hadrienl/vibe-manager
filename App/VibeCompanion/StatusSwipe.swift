import CompanionCore
import SwiftUI

extension View {
  /// A row swiped as the Mac's sidebar swipes it (#80, #400): to the right, the columns before the
  /// session's; to the left, the ones after; nearest to the row first. The system's swipe actions
  /// rather than a drag of our own, which took the list's scrolling from it (#446).
  func statusSwipe(
    of session: RemoteSession, choose: @escaping (RemoteTaskStatus) -> Void
  ) -> some View {
    swipeActions(edge: .leading, allowsFullSwipe: false) {
      ForEach(session.status.previous, id: \.self) { status in
        StatusSwipeButton(status: status) { choose(status) }
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      ForEach(session.status.next, id: \.self) { status in
        StatusSwipeButton(status: status) { choose(status) }
      }
    }
  }
}

private struct StatusSwipeButton: View {
  let status: RemoteTaskStatus
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(status.buttonTitle, systemImage: status.symbol)
    }
    .tint(status.tint)
  }
}
