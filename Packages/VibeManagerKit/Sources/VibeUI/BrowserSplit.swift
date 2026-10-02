import SwiftUI
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// The terminal, and the web view beside it with the divider between them (#69, #218).
///
/// The web view's width is read here alone: a drag of the divider evaluates this view again at
/// each step, not the window around it. Meanwhile, and while the web view slides in or out, the
/// panes beside it keep their width (`PaneWidthHold`), and are laid out again once it is over.
struct BrowserSplit<Leading: View, Trailing: View>: View {
  let layout: WorkspaceLayoutController
  let sessionID: SessionID
  let placement: BrowserPlacement
  /// False when there is no web view to slide: an archived session has none.
  let canSlide: Bool
  let terminalMinimum: Double
  let leading: Leading
  let trailing: Trailing

  /// Whether the web view is sliding in or out: beside the terminal, still, while it slides out.
  @State private var isSliding = false
  /// How much of it shows while it slides, from 0 to 1, as the sidebars do.
  @State private var reveal: Double = 0
  @State private var hold: PaneWidthHold?
  /// Count the slides and the centrings: the end of one overtaken by the next must not undo it.
  @State private var slide = 0
  @State private var centring = 0
  @State private var dragPause: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// About the sidebars' own.
  private static var slideAnimation: Animation { .smooth(duration: 0.3) }
  /// How long the divider must stay still, while dragged, for the panes to take the width it
  /// gives them: enough to see the result before letting go, never at each step.
  private static var dragPauseDelay: Duration { .milliseconds(200) }

  init(
    layout: WorkspaceLayoutController, sessionID: SessionID, placement: BrowserPlacement,
    canSlide: Bool, terminalMinimum: Double, @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.layout = layout
    self.sessionID = sessionID
    self.placement = placement
    self.canSlide = canSlide
    self.terminalMinimum = terminalMinimum
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    GeometryReader { proxy in
      let container = Double(proxy.size.width)
      let handle = Double(SplitHandle.thickness)
      // The terminal keeps its eighty columns: the web view gives way first.
      let upper = WorkspaceLayout.browserWidthUpperBound(
        in: container, handle: handle, terminalMinimum: terminalMinimum)
      let width = min(layout.browserWidth, upper)
      let isBeside = placement == .beside
      // Read from the placement itself, not from what the last change of it left: never mounted
      // here and in turns with the terminal at once, nor missing for a pass.
      let mountsTrailing = isBeside || (isSliding && placement != .alternating)
      HStack(spacing: 0) {
        leading
          .environment(\.paneWidthHold, hold)
        // Always there, empty when the web view is not: the width it slides by needs a view to
        // animate from. Its content keeps its own width, the part not shown yet clipped.
        ZStack(alignment: .leading) {
          if mountsTrailing {
            HStack(spacing: 0) {
              SplitHandle(
                length: width,
                range: WorkspaceLayout.browserWidthRange.lowerBound...upper,
                label: Text("Divider between the terminal and the web view", bundle: .module),
                onChange: { dragged(to: $0, leadingWidth: container - handle - width) },
                onEnded: endDrag,
                onDoubleClick: { center(from: width, in: container) },
                help: Text(
                  "Drag to resize. Double-click to give both sides the same width.",
                  bundle: .module))
              trailing
                .frame(width: width)
            }
            // Sliding out, it is already closed: neither clicked, nor focused, nor read.
            .allowsHitTesting(isBeside)
            .accessibilityHidden(!isBeside)
          }
        }
        .frame(
          width: (isSliding ? reveal : isBeside ? 1 : 0) * (width + handle), alignment: .leading
        )
        .clipped()
      }
      .onChange(of: Arrangement(session: sessionID, placement: placement)) { old, new in
        follow(from: old, to: new, container: container)
      }
    }
  }

  private struct Arrangement: Equatable {
    let session: SessionID
    let placement: BrowserPlacement
  }

  /// Slides the web view in or out when it is opened or closed on the session on screen. Shown
  /// with another session, or put in turns with the terminal by a narrower window, it takes its
  /// place at once.
  private func follow(from old: Arrangement, to new: Arrangement, container: Double) {
    let opens = new.placement == .beside
    slide += 1
    dragPause?.cancel()
    dragPause = nil
    let slides =
      !reduceMotion && canSlide && old.session == new.session
      && old.placement != .alternating && new.placement != .alternating
    guard slides else {
      hold = nil
      isSliding = false
      return
    }
    let current = slide
    // The whole column is the widest the panes are, before the slide or after it: laid out at
    // it, they are only covered and uncovered by the web view.
    hold = PaneWidthHold(width: container, isCovered: true)
    // From where it shows now, a slide overtaken included.
    if !isSliding { reveal = opens ? 0 : 1 }
    isSliding = true
    withAnimation(Self.slideAnimation) {
      reveal = opens ? 1 : 0
    } completion: {
      guard current == slide else { return }
      hold = nil
      isSliding = false
    }
  }

  /// The panes keep the width they had when the drag started, and take the new one when the
  /// divider pauses, or is let go.
  private func dragged(to width: Double, leadingWidth: Double) {
    if hold == nil {
      hold = PaneWidthHold(width: leadingWidth, isCovered: false)
    }
    layout.browserWidthChanged(to: width)
    dragPause?.cancel()
    dragPause = Task { @MainActor in
      try? await Task.sleep(for: Self.dragPauseDelay)
      guard !Task.isCancelled else { return }
      hold = nil
    }
  }

  private func endDrag() {
    dragPause?.cancel()
    dragPause = nil
    hold = nil
  }

  private func center(from width: Double, in container: Double) {
    let handle = Double(SplitHandle.thickness)
    let centered = WorkspaceLayout.centeredBrowserWidth(
      in: container, handle: handle, terminalMinimum: terminalMinimum)
    guard !reduceMotion else {
      layout.browserWidthChanged(to: centered)
      return
    }
    centring += 1
    let current = (centring, slide)
    hold = PaneWidthHold(width: container - handle - min(width, centered), isCovered: true)
    withAnimation(.easeOut(duration: 0.2)) {
      layout.browserWidthChanged(to: centered)
    } completion: {
      // A slide started meanwhile releases the hold itself, at its own end.
      guard current == (centring, slide) else { return }
      hold = nil
    }
  }
}
