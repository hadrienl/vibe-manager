import AppKit
import SwiftUI
import VibeDomain

/// The part of the line that ties a coordinator to its children a row of the sidebar draws
/// (#387). Each row draws its own piece, so that the line is made of the rows the list lays out.
enum FamilyLine: Equatable {
  /// A coordinator with children listed under it: the line leaves from under its badge.
  case parent
  /// A row of the family under it — a child, or the row of its done children — reached by an
  /// elbow. The last one ends the line.
  case child(isLast: Bool)
}

extension SidebarItem {
  /// The coordinator whose family the row belongs to, when it is listed as one of its children.
  fileprivate var familyOwner: SessionID? {
    switch self {
    case .session(let session): session.coordination?.coordinatorID
    case .doneChildren(let coordinator, _): coordinator
    }
  }

  /// The line each row draws, by `id`. Only rows listed right under their coordinator, or under a
  /// sibling that is, are tied to it: a folded coordinator, or a child a search shows alone,
  /// draws none.
  static func familyLines(of items: [SidebarItem]) -> [String: FamilyLine] {
    var lines: [String: FamilyLine] = [:]
    var family: SessionID?
    for (index, item) in items.enumerated() {
      let next = items.indices.contains(index + 1) ? items[index + 1] : nil
      if let owner = item.familyOwner, owner == family {
        lines[item.id] = .child(isLast: next?.familyOwner != owner)
        continue
      }
      family = nil
      if case .session(let session) = item, let next, next.familyOwner == session.id {
        lines[item.id] = .parent
        family = session.id
      }
    }
    return lines
  }
}

/// Where the pieces of the line run in a row, in the row's own coordinates: from its top-leading
/// corner, the badges set as `SessionRow` sets them.
enum FamilyLineGeometry {
  struct Segment: Equatable {
    let from: CGPoint
    let to: CGPoint
  }

  static let lineWidth: CGFloat = 1.5
  /// Between the line and the badges it leaves from or reaches.
  static let gap: CGFloat = 3
  /// Under the middle of the coordinator's badge.
  static var x: CGFloat { SessionRow.disclosureMargin + SessionRow.badgeSize / 2 }
  /// How far a piece that goes on runs past its row, up and down. The list sets a row's content
  /// in from the edges of its cell (4 pt each way on the sidebar of macOS 27), and the cell cuts
  /// whatever runs past its edge: running past by more than the inset meets the next piece
  /// exactly at the edge between the cells, without overlapping it.
  static let overrun: CGFloat = 8
  /// Where a child's elbow stops: short of its badge.
  static var elbowEnd: CGFloat { SessionRow.disclosureMargin + SessionRow.childIndent - gap }

  static func segments(of line: FamilyLine, height: CGFloat) -> [Segment] {
    let middle = height / 2
    switch line {
    case .parent:
      return [
        Segment(
          from: CGPoint(x: x, y: middle + SessionRow.badgeSize / 2 + gap),
          to: CGPoint(x: x, y: height + overrun))
      ]
    case .child(let isLast):
      return [
        Segment(
          from: CGPoint(x: x, y: -overrun),
          to: CGPoint(x: x, y: isLast ? middle : height + overrun)),
        Segment(from: CGPoint(x: x, y: middle), to: CGPoint(x: elbowEnd, y: middle)),
      ]
    }
  }
}

/// A row's piece of the line, behind it. One path, stroked once: where the elbow leaves the
/// line, the two do not darken each other.
struct FamilyLineView: View {
  let line: FamilyLine

  var body: some View {
    GeometryReader { proxy in
      Path { path in
        for segment in FamilyLineGeometry.segments(of: line, height: proxy.size.height) {
          path.move(to: segment.from)
          path.addLine(to: segment.to)
        }
      }
      .stroke(Color.primary.opacity(0.25), lineWidth: FamilyLineGeometry.lineWidth)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Says when a row of the list is being dragged (#387): from a press in the list that puts
/// something on the drag pasteboard, until the button is released. The table tracks the press
/// itself, so its drag never reaches a monitor; the pasteboard it writes to does change.
struct ListDragWatch: NSViewRepresentable {
  var changed: (_ isDragging: Bool) -> Void

  func makeNSView(context: Context) -> WatchView {
    let view = WatchView()
    view.changed = changed
    return view
  }

  func updateNSView(_ view: WatchView, context: Context) {
    view.changed = changed
  }

  static func dismantleNSView(_ view: WatchView, coordinator: ()) {
    view.stop()
  }

  final class WatchView: NSView {
    var changed: ((Bool) -> Void)?
    private var monitor: Any?
    private var watch: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        let windowNumber = event.windowNumber
        let location = event.locationInWindow
        // Local monitors run on the main thread, where this view lives.
        MainActor.assumeIsolated { self?.pressed(windowNumber: windowNumber, at: location) }
        return event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      watch?.cancel()
      watch = nil
    }

    private func pressed(windowNumber: Int, at location: CGPoint) {
      guard windowNumber == window?.windowNumber, bounds.contains(convert(location, from: nil))
      else { return }
      watch?.cancel()
      let start = NSPasteboard(name: .drag).changeCount
      watch = Task { [weak self] in
        var isDragging = false
        while !Task.isCancelled, DragEndWatch.isButtonDown() {
          if !isDragging, NSPasteboard(name: .drag).changeCount != start {
            isDragging = true
            self?.changed?(true)
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
        if isDragging { self?.changed?(false) }
      }
    }
  }
}
