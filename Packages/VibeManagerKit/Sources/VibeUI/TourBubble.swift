import AppKit
import SwiftUI
import VibeDomain

/// One bubble of the first launch's tour (#338): a title, a sentence or two, where the user is,
/// and the ways out.
///
/// The same content in both its hosts: a popover where the user has nothing to type, and a bubble
/// drawn in the window over the draft, where a popover would take the keyboard from the field it
/// describes.
struct TourBubble: View {
  let bubble: OnboardingModel.Bubble
  let advance: () -> Void
  let skip: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let progress = bubble.progress {
        Text(verbatim: progress)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(verbatim: bubble.title)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(verbatim: bubble.message)
        .font(.callout)
        // Whatever the list it is shown from: a sidebar's keeps its texts to one line.
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        if bubble.advance != .done {
          Button(action: skip) {
            Text("Skip Tutorial", bundle: .module, comment: "Ends the tutorial for good.")
          }
          .buttonStyle(.link)
          .font(.callout)
          .accessibilityIdentifier("onboarding-skip")
        }
        Spacer(minLength: 0)
        switch bubble.advance {
        case .next:
          Button(action: advance) {
            Text("Next", bundle: .module, comment: "Goes to the tutorial's next step.")
          }
          .controlSize(.small)
          .accessibilityIdentifier("onboarding-next")
        case .done:
          Button(action: advance) {
            Text("Done", bundle: .module, comment: "Closes the tutorial's last bubble.")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .accessibilityIdentifier("onboarding-done")
        case nil:
          EmptyView()
        }
      }
      .padding(.top, 4)
    }
    .padding(14)
    .frame(width: 290, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Tutorial", bundle: .module, comment: "VoiceOver: a tutorial bubble."))
    .accessibilityIdentifier("onboarding-bubble")
    // Read as it appears, and again when it changes in place.
    .task(id: bubble) { Announcer.announce(bubble.announcement) }
  }
}

// MARK: - Popover host

/// The tour's bubble as a popover on `target`: New Session, or the session's row. Nothing is typed
/// at these steps, and a popover reaches where an anchor cannot — a toolbar item, a cell of the
/// sidebar's list.
///
/// An AppKit popover the tour opens and closes itself: SwiftUI's closes at the first click outside
/// it and keeps that click, so the button it points at had to be clicked twice. This one lets the
/// click through, and goes when the tour moves on. Escape, once it holds the keyboard, closes it
/// until its target comes back on screen or the tour moves on; the tour goes on underneath.
///
/// Shown once its target has stopped moving: presented during the window's first layout, it kept
/// the frame the target had before the split view placed it, and pointed at the window's edge.
/// After that it follows its target — the row the swipe demo slides included.
struct TourPopover: ViewModifier {
  let model: AppModel
  let target: TourTarget
  var arrowEdge: Edge = .bottom
  /// Whether this target is the one the step points at: New Session lives in two places.
  var isEligible = true
  @State private var isClosed = false
  /// Where the target is in the window, and whether it stopped moving once.
  @State private var frame = CGRect.zero
  @State private var isSettled = false
  @Environment(\.controlActiveState) private var activeState

  private var step: OnboardingStep? {
    guard isEligible, activeState != .inactive else { return nil }
    return model.tourStep(on: target)
  }

  func body(content: Content) -> some View {
    let step = step
    let shown = step.flatMap { step in isClosed || !isSettled ? nil : step }
    content
      .background(
        TourPopoverAnchor(
          bubble: shown.map { step in
            TourBubble(
              bubble: model.tourBubble(for: step),
              advance: { model.onboarding.send(.next) },
              skip: { model.onboarding.send(.skip) }
            )
            .onExitCommand { isClosed = true }
          },
          edge: arrowEdge)
      )
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        frame = $0
      }
      .task(id: step) {
        isSettled = false
        guard step != nil else { return }
        // Still for a moment, at a place of its own.
        var last = CGRect.null
        while !Task.isCancelled, frame.isEmpty || frame != last {
          last = frame
          try? await Task.sleep(for: .milliseconds(250))
        }
        if !Task.isCancelled { isSettled = true }
      }
      .onChange(of: step) { isClosed = false }
      .onAppear { isClosed = false }
  }
}

/// The view an AppKit popover is shown from, behind the target: it opens the popover while there
/// is a bubble, puts the new bubble in it, and closes it when there is none.
private struct TourPopoverAnchor<Bubble: View>: NSViewRepresentable {
  let bubble: Bubble?
  let edge: Edge

  func makeCoordinator() -> TourPopoverController { TourPopoverController() }

  func makeNSView(context: Context) -> TourPopoverAnchorView {
    let view = TourPopoverAnchorView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ view: TourPopoverAnchorView, context: Context) {
    let coordinator = context.coordinator
    guard let bubble else {
      coordinator.close()
      return
    }
    coordinator.show(AnyView(bubble), from: view, edge: edge.rectEdge)
  }

  static func dismantleNSView(_ view: TourPopoverAnchorView, coordinator: TourPopoverController) {
    coordinator.close()
  }
}

/// Opens, fills and closes the popover of one target.
@MainActor
private final class TourPopoverController {
  private var popover: NSPopover?
  private var host: NSHostingController<AnyView>?
  private var pending: (view: NSView, edge: NSRectEdge)?

  func show(_ content: AnyView, from view: NSView, edge: NSRectEdge) {
    if let host {
      host.rootView = content
    } else {
      let host = NSHostingController(rootView: content)
      host.sizingOptions = .preferredContentSize
      self.host = host
    }
    let popover = popover ?? makePopover()
    guard !popover.isShown else { return }
    // Once the view is in a window: SwiftUI asks for the popover before it is placed.
    guard view.window != nil else {
      pending = (view, edge)
      return
    }
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
  }

  /// The view arrived in its window, or moved: the popover follows it.
  func viewDidMove(_ view: NSView) {
    if let pending, pending.view === view, view.window != nil, let popover, !popover.isShown {
      self.pending = nil
      popover.show(relativeTo: view.bounds, of: view, preferredEdge: pending.edge)
    } else if let popover, popover.isShown {
      popover.positioningRect = view.bounds
    }
  }

  func close() {
    pending = nil
    popover?.close()
  }

  private func makePopover() -> NSPopover {
    let popover = NSPopover()
    // Not transient: a click outside goes where it was meant to, and the bubble stays.
    popover.behavior = .applicationDefined
    popover.animates = true
    popover.contentViewController = host
    self.popover = popover
    return popover
  }
}

/// Behind the target, the size of it: what the popover points at. Clicks go through it.
private final class TourPopoverAnchorView: NSView {
  weak var coordinator: TourPopoverController?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    coordinator?.viewDidMove(self)
  }

  override func layout() {
    super.layout()
    coordinator?.viewDidMove(self)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension Edge {
  /// The side of the target the popover's arrow comes from.
  fileprivate var rectEdge: NSRectEdge {
    switch self {
    case .top: .minY
    case .bottom: .maxY
    case .leading: .minX
    case .trailing: .maxX
    }
  }
}

extension View {
  func tourPopover(
    _ model: AppModel, on target: TourTarget, arrowEdge: Edge = .bottom, isEligible: Bool = true
  ) -> some View {
    modifier(
      TourPopover(model: model, target: target, arrowEdge: arrowEdge, isEligible: isEligible))
  }
}

extension View {
  /// Puts a button forward while the tour points at it.
  @ViewBuilder
  func tourProminent(_ isProminent: Bool) -> some View {
    if isProminent {
      buttonStyle(.borderedProminent)
    } else {
      self
    }
  }
}

// MARK: - Anchored host

/// Where the draft's targets are, for the bubble drawn over the draft.
struct TourAnchorKey: PreferenceKey {
  static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

extension View {
  /// Marks this view as what a bubble of the tour can point at, inside the draft.
  func tourAnchor(_ target: TourTarget) -> some View {
    anchorPreference(key: TourAnchorKey.self, value: .bounds) { [target: $0] }
  }
}

/// Where a bubble goes next to its target: under it when it fits, over it otherwise, never out of
/// the container. Kept apart from the view so that it can be tested without one.
struct TourBubblePlacement: Equatable {
  static let margin: CGFloat = 10
  static let arrowLength: CGFloat = 8
  /// How far the arrow stays from the bubble's corners.
  static let arrowInset: CGFloat = 22

  /// The bubble's top-left corner, in the container.
  let origin: CGPoint
  /// Whether the bubble sits under its target, its arrow on its top edge.
  let isBelow: Bool
  /// Where the arrow's tip is along the bubble's width.
  let arrowX: CGFloat

  /// - Parameter prefersAbove: over the target when it fits, for a target whose foot holds what
  ///   the bubble asks the user to use next.
  init(bubble: CGSize, target: CGRect, container: CGSize, prefersAbove: Bool = false) {
    let room = Self.arrowLength + Self.margin
    let below = container.height - target.maxY - room
    let above = target.minY - room
    isBelow =
      prefersAbove
      ? above < bubble.height && below > above
      : below >= bubble.height || below >= above
    let y =
      isBelow ? target.maxY + Self.arrowLength : target.minY - Self.arrowLength - bubble.height
    let maxX = max(Self.margin, container.width - Self.margin - bubble.width)
    let x = min(max(target.midX - bubble.width / 2, Self.margin), maxX)
    origin = CGPoint(
      x: x, y: min(max(y, Self.margin), max(Self.margin, container.height - bubble.height)))
    arrowX = min(
      max(target.midX - x, Self.arrowInset), max(Self.arrowInset, bubble.width - Self.arrowInset))
  }
}

/// A rounded rectangle with an arrow on its top or bottom edge.
struct TourBubbleShape: Shape {
  let isArrowOnTop: Bool
  let arrowX: CGFloat
  var cornerRadius: CGFloat = 12

  /// One outline, the arrow part of the edge it stands on: drawn as a shape of its own, it left
  /// the rectangle's border across its base.
  func path(in rect: CGRect) -> Path {
    let length = TourBubblePlacement.arrowLength
    let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
    let x = min(max(rect.minX + arrowX, rect.minX + radius + length), rect.maxX - radius - length)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    if isArrowOnTop {
      path.addLine(to: CGPoint(x: x - length, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: rect.minY - length))
      path.addLine(to: CGPoint(x: x + length, y: rect.minY))
    }
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
      tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
    if !isArrowOnTop {
      path.addLine(to: CGPoint(x: x + length, y: rect.maxY))
      path.addLine(to: CGPoint(x: x, y: rect.maxY + length))
      path.addLine(to: CGPoint(x: x - length, y: rect.maxY))
    }
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.minY),
      tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
    path.closeSubpath()
    return path
  }
}

/// The draft's bubble, drawn over the draft next to its target. It stays in the window: it never
/// takes the keyboard, and it follows its target as the draft scrolls or the window is resized.
struct TourAnchoredBubble: View {
  let anchors: [TourTarget: Anchor<CGRect>]
  let target: TourTarget?
  let bubble: OnboardingModel.Bubble?
  let advance: () -> Void
  let skip: () -> Void
  @State private var size = CGSize(width: 290, height: 120)

  var body: some View {
    GeometryReader { proxy in
      if let target, let bubble, let anchor = anchors[target] {
        let placement = TourBubblePlacement(
          bubble: size, target: proxy[anchor], container: proxy.size,
          // The options' bubble sends the user to the prompt under them: it keeps off it.
          prefersAbove: target == .draftOptions)
        let shape = TourBubbleShape(isArrowOnTop: placement.isBelow, arrowX: placement.arrowX)
        TourBubble(bubble: bubble, advance: advance, skip: skip)
          .background(.regularMaterial, in: shape)
          .overlay { shape.stroke(.separator) }
          .compositingGroup()
          .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
          .onGeometryChange(for: CGSize.self) {
            $0.size
          } action: {
            size = $0
          }
          .offset(x: placement.origin.x, y: placement.origin.y)
          .transition(.opacity)
      }
    }
  }
}
