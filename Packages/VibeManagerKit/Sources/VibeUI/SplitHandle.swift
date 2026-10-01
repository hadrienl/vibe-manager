import AppKit
import SwiftUI

/// The handle between two panes that share a length: seen, easy to grab, and driven from the
/// keyboard and VoiceOver. One component, so that every divider of the window reads the same way:
/// the web view's beside the terminal (#69), the context column's between its sections (#66), the
/// one above a session's drawer of side terminals (#43).
struct SplitHandle: View {
  enum Axis {
    /// Panes side by side; the length is the width of the pane after the handle, which grows as
    /// the handle moves left.
    case horizontal
    /// Panes stacked; the length is the height of the pane above the handle, which grows as the
    /// handle moves down.
    case vertical
  }

  var axis: Axis = .horizontal
  /// The length of the pane the handle sizes, as it is now.
  let length: Double
  let range: ClosedRange<Double>
  let label: Text
  /// What VoiceOver reads as the handle's value; the width in points when not given.
  var value: Text?
  /// How far one step of the keyboard or VoiceOver moves the handle.
  var step: Double = 40
  /// On the vertical axis, the length is the height of the pane *below* the handle, which grows as
  /// the handle moves up: the drawer of side terminals (#43).
  var sizesPaneBelow = false
  let onChange: (Double) -> Void
  /// Once the drag, or a step, is over: where a handle that only shows its length while it moves
  /// writes it for good.
  var onEnded: () -> Void = {
    // Nothing by default: the web view's width is written as it changes.
  }
  /// Gives both panes the same length: a double click, VoiceOver's “Center”, or Return or = once
  /// the handle has the keyboard.
  var onDoubleClick: (() -> Void)?
  /// What the handle's help tag says, if anything.
  var help: Text?

  @State private var dragged: Double?
  /// The length when the drag began: the drag's translation is counted from it, however often the
  /// view is redrawn meanwhile.
  @State private var startLength: Double?
  @State private var isHovering = false
  @State private var cursorPushed = false
  @FocusState private var isFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let thickness: CGFloat = 9

  var body: some View {
    let isActive = isHovering || dragged != nil || isFocused
    let line: CGFloat = isActive ? 3 : 1
    ZStack {
      Color.clear
      Rectangle()
        .fill(isActive ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor))
        .frame(width: axis == .horizontal ? line : nil)
        .frame(height: axis == .vertical ? line : nil)
    }
    .frame(width: axis == .horizontal ? Self.thickness : nil)
    .frame(height: axis == .vertical ? Self.thickness : nil)
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
      // A few points before a drag begins: the mouse trembling between the two clicks of a
      // double click must not move the handle before it is centred (#218).
      DragGesture(minimumDistance: 3, coordinateSpace: .global)
        .onChanged { value in
          let start = startLength ?? length
          startLength = start
          let next = bounded(
            axis == .horizontal
              ? start - Double(value.translation.width)
              : start + Double(value.translation.height) * verticalDirection)
          dragged = next
          onChange(next)
        }
        .onEnded { _ in
          dragged = nil
          startLength = nil
          onEnded()
          updateCursor()
        }
    )
    .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick?() })
    // Reached with Tab when Full Keyboard Access is on; the arrows then move it. Beside the
    // terminal, only by Tab: a click on the handle must leave the keyboard to the terminal.
    .focusable(interactions: axis == .vertical ? .automatic : .activate)
    .focused($isFocused)
    .focusEffectDisabled()
    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
      guard axis == .vertical else { return .ignored }
      adjust((press.key == .downArrow ? step : -step) * verticalDirection)
      return .handled
    }
    .onKeyPress(keys: [.return, KeyEquivalent("=")]) { _ in
      guard let onDoubleClick else { return .ignored }
      onDoubleClick()
      return .handled
    }
    .help(help ?? Text(verbatim: ""))
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue(
      value
        ?? Text(
          "\(Int(length)) points wide", bundle: .module,
          comment: "The width of the web view, read by VoiceOver on its divider.")
    )
    .accessibilityAdjustableAction { direction in
      adjust(direction == .increment ? step : -step)
    }
    .accessibilityActions {
      if let onDoubleClick {
        Button(
          String(
            localized: "Center", bundle: .module,
            comment: "VoiceOver's action on a divider: both panes take the same length."),
          action: onDoubleClick)
      }
    }
  }

  /// How the length follows a move down.
  private var verticalDirection: Double {
    sizesPaneBelow ? -1 : 1
  }

  private func adjust(_ delta: Double) {
    onChange(bounded(length + delta))
    onEnded()
  }

  private func bounded(_ value: Double) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  private func updateCursor() {
    let wanted = isHovering || dragged != nil
    if wanted, !cursorPushed {
      (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
      cursorPushed = true
    } else if !wanted, cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }
}
