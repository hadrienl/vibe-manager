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
/// at these steps, so a popover taking the keyboard costs nothing, and it reaches where an anchor
/// cannot — a toolbar item, a cell of the sidebar's list.
///
/// Closed by the user — Escape, a click elsewhere — it stays closed until its target comes back on
/// screen or the tour moves on, and the tour goes on underneath.
///
/// Shown only once its target has stayed where it is for a moment: presented during the window's
/// first layout, the popover kept the frame the target had before the split view placed it, and
/// pointed at the window's edge. A target that moves takes it down, and it comes back on the new
/// frame.
struct TourPopover: ViewModifier {
  let model: AppModel
  let target: TourTarget
  var arrowEdge: Edge = .bottom
  /// Whether this target is the one the step points at: New Session lives in two places.
  var isEligible = true
  @State private var isClosed = false
  /// Where the target is in the window, and whether it has stayed there long enough.
  @State private var frame = CGRect.zero
  @State private var isSettled = false
  @Environment(\.controlActiveState) private var activeState

  private var step: OnboardingStep? {
    guard isEligible, activeState != .inactive else { return nil }
    return model.tourStep(on: target)
  }

  func body(content: Content) -> some View {
    let step = step
    content
      .popover(
        isPresented: Binding(
          get: { step != nil && !isClosed && isSettled },
          set: { isShown in
            if !isShown, step != nil { isClosed = true }
          }),
        arrowEdge: arrowEdge
      ) {
        if let step {
          TourBubble(
            bubble: model.tourBubble(for: step),
            advance: { model.onboarding.send(.next) },
            skip: { model.onboarding.send(.skip) })
        }
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        frame = $0
      }
      .task(id: Settling(isWanted: step != nil, frame: frame)) {
        isSettled = false
        guard step != nil, !frame.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(300))
        if !Task.isCancelled { isSettled = true }
      }
      .onChange(of: step) { isClosed = false }
      .onAppear { isClosed = false }
  }
}

/// What the popover waits on before it shows: wanted, on a target that stopped moving.
private struct Settling: Equatable {
  let isWanted: Bool
  let frame: CGRect
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
  static let arrowInset: CGFloat = 18

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

  func path(in rect: CGRect) -> Path {
    let length = TourBubblePlacement.arrowLength
    var path = Path(roundedRect: rect, cornerRadius: cornerRadius)
    let x = rect.minX + arrowX
    var arrow = Path()
    if isArrowOnTop {
      arrow.move(to: CGPoint(x: x - length, y: rect.minY + 0.5))
      arrow.addLine(to: CGPoint(x: x, y: rect.minY - length))
      arrow.addLine(to: CGPoint(x: x + length, y: rect.minY + 0.5))
    } else {
      arrow.move(to: CGPoint(x: x - length, y: rect.maxY - 0.5))
      arrow.addLine(to: CGPoint(x: x, y: rect.maxY + length))
      arrow.addLine(to: CGPoint(x: x + length, y: rect.maxY - 0.5))
    }
    arrow.closeSubpath()
    path.addPath(arrow)
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
