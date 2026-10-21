import CompanionCore
import SwiftUI

/// A row swiped as the Mac's sidebar swipes it (#80, #400): to the right, the columns before the
/// session's on its left; to the left, the ones after on its right; nearest to the row first.
/// Nothing changes until a button is touched. The system's swipe actions draw round buttons
/// under the row: these are the Mac's, coloured blocks side by side.
struct StatusSwipe<Content: View>: View {
  let id: String
  /// Nearest first.
  let leading: [RemoteTaskStatus]
  let trailing: [RemoteTaskStatus]
  /// The one row open at a time.
  @Binding var openID: String?
  let choose: (RemoteTaskStatus) -> Void
  let tap: () -> Void
  @ViewBuilder let content: Content

  static var buttonWidth: CGFloat { 76 }
  static var gap: CGFloat { 8 }

  @State private var settled: CGFloat = 0
  @State private var dragging: CGFloat = 0
  @State private var isHorizontal: Bool?

  var body: some View {
    let offset = elastic(settled + dragging)
    content
      .contentShape(Rectangle())
      .offset(x: offset)
      .background(alignment: .leading) {
        if offset > 0 {
          buttons(leading.reversed(), width: offset - Self.gap)
        }
      }
      .background(alignment: .trailing) {
        if offset < 0 {
          buttons(trailing, width: -offset - Self.gap)
        }
      }
      .onTapGesture {
        if settled != 0 { close() } else { tap() }
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 12)
          .onChanged { value in
            if isHorizontal == nil {
              isHorizontal = abs(value.translation.width) > abs(value.translation.height)
            }
            guard isHorizontal == true else { return }
            if openID != id { openID = id }
            dragging = value.translation.width
          }
          .onEnded { value in
            defer { isHorizontal = nil }
            guard isHorizontal == true else { return }
            let target = settled + value.predictedEndTranslation.width
            withAnimation(.snappy) {
              dragging = 0
              if target > width(of: leading) * 0.4, !leading.isEmpty {
                settled = width(of: leading)
              } else if target < -width(of: trailing) * 0.4, !trailing.isEmpty {
                settled = -width(of: trailing)
              } else {
                settled = 0
              }
            }
          }
      )
      .onChange(of: openID) { _, open in
        if open != id, settled != 0 { close() }
      }
  }

  private func width(of statuses: [RemoteTaskStatus]) -> CGFloat {
    statuses.isEmpty ? 0 : CGFloat(statuses.count) * Self.buttonWidth + Self.gap
  }

  /// Follows the finger up to the buttons, and gives way past them; a side without buttons barely
  /// moves, to say there is nothing there.
  private func elastic(_ x: CGFloat) -> CGFloat {
    let limit = x > 0 ? width(of: leading) : width(of: trailing)
    let bare: CGFloat = 36
    let reach = limit == 0 ? bare : limit
    let magnitude = abs(x)
    let moved = magnitude <= reach ? magnitude : reach + (magnitude - reach) * 0.25
    return x < 0 ? -moved : moved
  }

  private func close() {
    withAnimation(.snappy) {
      settled = 0
      dragging = 0
    }
  }

  private func buttons(_ statuses: [RemoteTaskStatus], width: CGFloat) -> some View {
    HStack(spacing: 0) {
      ForEach(statuses, id: \.self) { status in
        Button {
          close()
          choose(status)
        } label: {
          VStack(spacing: 2) {
            Image(systemName: status.symbol)
              .font(.body.weight(.semibold))
            Text(status.buttonTitle)
              .font(.caption2.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 2)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(status.tint)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(status.buttonTitle))
      }
    }
    .frame(width: max(0, width))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .padding(.vertical, 4)
  }
}
