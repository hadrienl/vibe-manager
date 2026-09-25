import AppKit
import SwiftUI

/// The handle between two panes that share a width: seen, easy to grab, and driven from the
/// keyboard and VoiceOver (#69). One component, so that every divider of the window reads the same
/// way — #66 takes it for the context column's sections.
struct SplitHandle: View {
  /// The width of the pane after the handle, as it is now.
  let width: Double
  let range: ClosedRange<Double>
  let label: Text
  let onChange: (Double) -> Void

  @State private var dragged: Double?
  /// The width when the drag began: the drag's translation is counted from it, however often the
  /// view is redrawn meanwhile.
  @State private var startWidth: Double?
  @State private var isHovering = false
  @State private var cursorPushed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let thickness: CGFloat = 9

  var body: some View {
    let isActive = isHovering || dragged != nil
    ZStack {
      Color.clear
      Rectangle()
        .fill(isActive ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor))
        .frame(width: isActive ? 3 : 1)
    }
    .frame(width: Self.thickness)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isActive)
    .contentShape(Rectangle())
    .onHover { inside in
      isHovering = inside
      updateCursor()
    }
    .onDisappear {
      if cursorPushed { NSCursor.pop() }
      cursorPushed = false
    }
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { value in
          let start = startWidth ?? width
          startWidth = start
          // The pane after the handle grows as the handle moves left.
          let next = bounded(start - Double(value.translation.width))
          dragged = next
          onChange(next)
        }
        .onEnded { _ in
          dragged = nil
          startWidth = nil
          updateCursor()
        }
    )
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue(
      Text(
        "\(Int(width)) points wide", bundle: .module,
        comment: "The width of the web view, read by VoiceOver on its divider.")
    )
    .accessibilityAdjustableAction { direction in
      onChange(bounded(width + (direction == .increment ? 40 : -40)))
    }
  }

  private func bounded(_ value: Double) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  private func updateCursor() {
    let wanted = isHovering || dragged != nil
    if wanted, !cursorPushed {
      NSCursor.resizeLeftRight.push()
      cursorPushed = true
    } else if !wanted, cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }
}
