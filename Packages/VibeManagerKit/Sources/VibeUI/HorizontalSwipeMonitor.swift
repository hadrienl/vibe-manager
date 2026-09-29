import AppKit
import SwiftUI
import VibeDomain

/// Hands a two-finger horizontal swipe over the view it backs to SwiftUI (#80).
///
/// A `List` on the Mac scrolls on every wheel event, so a swipe on one of its rows has to be taken
/// before the list sees it. A local monitor does that for the events that fall inside this view,
/// in its own window, and only for a gesture that starts out horizontal — the way Mail tells a
/// swipe from a scroll. Everything else goes through untouched, the list's own scrolling included,
/// and so does the end of a swipe, so that the list never waits for the end of a gesture it saw
/// begin.
///
/// The row is found where the fingers are, by the `SwipeRowMarker` drawn behind it in the window,
/// rather than from the last row the pointer entered — a list scrolled under a still pointer does
/// not say it moved — or from the table's row numbers, which do not count the same rows from one
/// SDK to the next.
///
/// The inertia that follows a swipe is swallowed and not followed: the decision is taken when the
/// fingers leave the trackpad.
struct HorizontalSwipeMonitor: NSViewRepresentable {
  /// Asked when a gesture turns out horizontal, with the session of the row under the fingers.
  /// `false` leaves the gesture to the list.
  var began: (_ sessionID: SessionID?) -> Bool
  /// The distance the fingers moved since the last call, positive to the right.
  var changed: (CGFloat) -> Void
  var ended: () -> Void
  /// A click in the list, with the session of the row it landed on: its content, not the buttons
  /// a swipe uncovered beside it.
  var clicked: (_ sessionID: SessionID?) -> Void
  /// A gesture that turned out to be a scroll, or a click outside this view.
  var interrupted: () -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.handlers = self
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.handlers = self
  }

  static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
    view.stopMonitoring()
  }

  /// What the monitor reads of an event, taken out of it before it crosses to the main actor:
  /// `NSEvent` is not `Sendable`.
  struct Sample: Sendable {
    let windowNumber: Int
    let isPrecise: Bool
    let phase: UInt
    let momentumPhase: UInt
    let deltaX: CGFloat
    let deltaY: CGFloat
    let isInverted: Bool
    let location: CGPoint

    init(_ event: NSEvent) {
      windowNumber = event.windowNumber
      isPrecise = event.hasPreciseScrollingDeltas
      phase = event.phase.rawValue
      momentumPhase = event.momentumPhase.rawValue
      deltaX = event.scrollingDeltaX
      deltaY = event.scrollingDeltaY
      isInverted = event.isDirectionInvertedFromDevice
      location = event.locationInWindow
    }
  }

  final class MonitorView: NSView {
    var handlers: HorizontalSwipeMonitor?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var tracking = Tracking.idle
    /// Set once a swipe has been taken, until its inertia is over.
    private var swallowsMomentum = false

    private enum Tracking {
      case idle
      /// Not yet sure whether the gesture is a swipe or a scroll.
      case deciding(x: CGFloat, y: CGFloat)
      case claimed
      case declined
    }

    /// Movement, in points, before the gesture is judged.
    private static let decisionDistance: CGFloat = 4

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        let sample = Sample(event)
        // Local monitors run on the main thread, where this view lives.
        let consumed = MainActor.assumeIsolated { self?.consumes(sample) ?? false }
        return consumed ? nil : event
      }
      clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        let windowNumber = event.windowNumber
        let location = event.locationInWindow
        MainActor.assumeIsolated { self?.noteClick(windowNumber: windowNumber, at: location) }
        return event
      }
    }

    func stopMonitoring() {
      if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
      if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
      scrollMonitor = nil
      clickMonitor = nil
    }

    private func noteClick(windowNumber: Int, at location: CGPoint) {
      guard windowNumber == window?.windowNumber else { return }
      if bounds.contains(convert(location, from: nil)) {
        handlers?.clicked(sessionID(at: location))
      } else {
        handlers?.interrupted()
      }
    }

    /// Whether the event is this monitor's to keep from the list.
    private func consumes(_ event: Sample) -> Bool {
      guard event.windowNumber == window?.windowNumber, event.isPrecise else { return false }

      let momentum = NSEvent.Phase(rawValue: event.momentumPhase)
      if momentum != [] {
        let swallowed = swallowsMomentum
        if momentum.contains(.ended) || momentum.contains(.cancelled) {
          swallowsMomentum = false
        }
        return swallowed
      }

      // With natural scrolling the content follows the fingers, and the deltas already say where
      // they went. Without it, the deltas are the other way round.
      let fingerX = event.isInverted ? event.deltaX : -event.deltaX
      let phase = NSEvent.Phase(rawValue: event.phase)

      if phase.contains(.began) {
        swallowsMomentum = false
        tracking =
          bounds.contains(convert(event.location, from: nil)) ? .deciding(x: 0, y: 0) : .idle
        return false
      }
      if phase.contains(.changed) {
        switch tracking {
        case .deciding(let x, let y):
          let x = x + fingerX
          let y = y + event.deltaY
          guard hypot(x, y) >= Self.decisionDistance else {
            tracking = .deciding(x: x, y: y)
            return false
          }
          guard abs(x) > abs(y) * 1.2, handlers?.began(sessionID(at: event.location)) == true else {
            tracking = .declined
            handlers?.interrupted()
            return false
          }
          tracking = .claimed
          handlers?.changed(x)
          return true
        case .claimed:
          handlers?.changed(fingerX)
          return true
        case .idle, .declined:
          return false
        }
      }
      if phase.contains(.ended) || phase.contains(.cancelled) {
        if case .claimed = tracking {
          swallowsMomentum = true
          handlers?.ended()
        }
        tracking = .idle
        // Let through: the list saw the gesture begin, and must see it end.
        return false
      }
      if case .claimed = tracking { return true }
      return false
    }

    /// The session of the row drawn under a point of the window, if the list draws one there.
    private func sessionID(at location: CGPoint) -> SessionID? {
      guard bounds.contains(convert(location, from: nil)), let content = window?.contentView
      else { return nil }
      return Self.marker(in: content, at: location)?.sessionID
    }

    private static func marker(in view: NSView, at location: CGPoint) -> SwipeRowMarker.MarkerView?
    {
      let frame = view.convert(view.bounds, to: nil)
      if let marker = view as? SwipeRowMarker.MarkerView {
        return frame.contains(location) ? marker : nil
      }
      // A view with a size draws its rows inside it: the terminals and the web view are skipped.
      if !frame.isEmpty, !frame.contains(location) { return nil }
      for subview in view.subviews where !subview.isHidden {
        if let marker = marker(in: subview, at: location) { return marker }
      }
      return nil
    }
  }
}

/// Behind a row of the list, says which session it draws, so that `HorizontalSwipeMonitor` can
/// find the row under the fingers where it is really drawn.
///
/// It also carries the row's selection while the row slides. The list draws that rounded
/// background itself, in the table row behind the cell, where SwiftUI's offset does not reach:
/// without it the content of a selected row left its background behind, alone under the buttons.
struct SwipeRowMarker: NSViewRepresentable {
  let sessionID: SessionID
  var carriesSelection = false

  func makeNSView(context: Context) -> MarkerView {
    let view = MarkerView()
    view.sessionID = sessionID
    return view
  }

  func updateNSView(_ view: MarkerView, context: Context) {
    view.sessionID = sessionID
    view.carriesSelection = carriesSelection
  }

  static func dismantleNSView(_ view: MarkerView, coordinator: ()) {
    view.carriesSelection = false
  }

  final class MarkerView: NSView {
    var sessionID: SessionID?
    var carriesSelection = false {
      didSet { if carriesSelection != oldValue { followRow() } }
    }
    /// Stands in for the list's selection, hidden meanwhile. A subview of this view, which SwiftUI
    /// moves with the row, frame for frame, animations included: the list's own selection is laid
    /// out and its layer reset by the table whenever it likes, and a card of its own moved beside
    /// the row lags behind it.
    private var card: NSVisualEffectView?
    private weak var hiddenSelection: NSView?
    /// Where the table row is, seen from here while the row is at rest: the card is drawn where
    /// the selection is drawn then.
    private var restingRowOrigin: NSPoint?
    /// The row selected or not, focused or not, while the card stands in for its selection.
    private var rowObservations: [NSKeyValueObservation] = []

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
      super.layout()
      if !carriesSelection { restingRowOrigin = row.map { convert(NSPoint.zero, from: $0) } }
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      needsLayout = true
    }

    /// A row the table takes back, or hands to another session, never keeps a hidden selection.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
      if newSuperview == nil { carriesSelection = false }
      super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { carriesSelection = false }
      super.viewWillMove(toWindow: newWindow)
    }

    /// The selection can come to an open row, or leave it, from the keyboard, and the list draws
    /// it dimmer once the keyboard or the window is elsewhere: the card follows. The table draws
    /// the selection after it says so.
    private func followRow() {
      rowObservations = []
      if carriesSelection, let row {
        let changed: @Sendable (NSTableRowView, NSKeyValueObservedChange<Bool>) -> Void = {
          [weak self] _, _ in
          Task { @MainActor in self?.updateCard() }
        }
        rowObservations = [
          row.observe(\.isSelected, changeHandler: changed),
          row.observe(\.isEmphasized, changeHandler: changed),
        ]
      }
      updateCard()
    }

    /// On a system that draws the selection otherwise, nothing moves.
    private func updateCard() {
      guard carriesSelection, let row, row.isSelected, let origin = restingRowOrigin,
        let selection = row.subviews.first(where: { $0 is NSVisualEffectView })
      else {
        card?.removeFromSuperview()
        card = nil
        hiddenSelection?.alphaValue = 1
        hiddenSelection = nil
        return
      }
      let card = self.card ?? NSVisualEffectView()
      if card.superview !== self { addSubview(card) }
      self.card = card
      if let effect = selection as? NSVisualEffectView {
        card.material = effect.material
        card.blendingMode = effect.blendingMode
        card.state = effect.state
        card.isEmphasized = effect.isEmphasized
        card.maskImage =
          effect.maskImage ?? Self.roundedMask(radius: effect.layer?.cornerRadius ?? 0)
      }
      card.frame = selection.frame.offsetBy(dx: origin.x, dy: origin.y)
      selection.alphaValue = 0
      hiddenSelection = selection
    }

    private var row: NSTableRowView? {
      var ancestor = superview
      while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
      return ancestor as? NSTableRowView
    }

    private static func roundedMask(radius: CGFloat) -> NSImage? {
      guard radius > 0 else { return nil }
      let side = radius * 2 + 1
      let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
      }
      image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
      image.resizingMode = .stretch
      return image
    }
  }
}
