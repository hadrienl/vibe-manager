import AppKit
import SwiftUI
import VibeApplication

/// One expression of an avatar. Decorative: what it means, the bubble says.
public struct AvatarView: View {
  let images: [AvatarExpression: NSImage]
  let expression: AvatarExpression
  let size: CGFloat

  public init(images: [AvatarExpression: NSImage], expression: AvatarExpression, size: CGFloat) {
    self.images = images
    self.expression = expression
    self.size = size
  }

  public var body: some View {
    Group {
      if let image = images[expression] ?? images[.neutral] {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        // No avatar at all: the requests are still shown, by a plain symbol.
        Image(systemName: "hand.raised.circle.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(.orange)
          .padding(size * 0.12)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Where the bubble opens from the avatar: toward the inside of the screen.
public struct FloatingPanelLayout: Equatable, Sendable {
  /// The bubble is on the avatar's leading side.
  public var bubbleLeading: Bool
  /// Avatar and bubble are aligned on their bottom edge: the bubble grows upward.
  public var alignedBottom: Bool

  public init(bubbleLeading: Bool = true, alignedBottom: Bool = true) {
    self.bubbleLeading = bubbleLeading
    self.alignedBottom = alignedBottom
  }
}

/// The floating panel's content (#41): the avatar, and beside it the bubble with one request,
/// answered with the palette's own card.
struct FloatingRequestPanel: View {
  static let avatarSize: CGFloat = 72
  static let padding: CGFloat = 8
  static let bubbleWidth: CGFloat = 340

  @Bindable var model: AppModel
  @Bindable var panel: FloatingRequestPanelModel
  let animator: AvatarAnimator
  let layout: FloatingPanelLayout
  /// The most height the bubble takes, scrolling past it.
  let maxBubbleHeight: CGFloat
  /// The avatar was dragged by `delta` since the gesture began, in points of the screen; `nil`
  /// when the drag ends.
  let onDrag: (CGSize?) -> Void
  /// Escape, or an answer sent: the keyboard goes back to the application in front.
  let onReleaseKeyboard: () -> Void

  @FocusState private var bubbleFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dragStart: NSPoint?

  var body: some View {
    let current = panel.current
    HStack(alignment: layout.alignedBottom ? .bottom : .top, spacing: 4) {
      if layout.bubbleLeading { bubble(current) }
      avatar(count: panel.requests.count)
      if !layout.bubbleLeading { bubble(current) }
    }
    .padding(Self.padding)
    .fixedSize()
    .onAppear {
      animator.reducesMotion = reduceMotion
      animator.start()
      if let current, !panel.isCollapsed {
        animator.send(.requestArrived(speech: FloatingRequestPanelModel.speech(of: current)))
      }
    }
    .onDisappear { animator.stop() }
    .onChange(of: reduceMotion) { _, reduces in animator.reducesMotion = reduces }
    .onChange(of: panel.requests.map(\.id)) { old, new in
      guard Set(new).subtracting(old).isEmpty == false else { return }
      let speech = panel.isCollapsed ? nil : panel.current.map(FloatingRequestPanelModel.speech)
      animator.send(.requestArrived(speech: speech))
    }
    .onChange(of: current?.id) { _, id in
      guard id != nil, let current = panel.current, !panel.isCollapsed else {
        if id == nil { animator.send(.bubbleClosed) }
        return
      }
      animator.send(.bubbleShown(speech: FloatingRequestPanelModel.speech(of: current)))
    }
    .onChange(of: panel.isCollapsed) { _, collapsed in
      if collapsed {
        animator.send(.bubbleClosed)
      } else if let current = panel.current {
        animator.send(.bubbleShown(speech: FloatingRequestPanelModel.speech(of: current)))
      }
    }
    .onChange(of: model.answeringRequestIDs) { old, new in
      if !new.subtracting(old).isEmpty { animator.send(.answerSending) }
    }
    .onChange(of: model.requestOutcome?.id) { _, id in
      guard id != nil, let outcome = model.requestOutcome else { return }
      if outcome.outcome == .sent {
        animator.send(
          .answerSucceeded(
            next: panel.isCollapsed ? nil : panel.current.map(FloatingRequestPanelModel.speech)))
        onReleaseKeyboard()
      } else {
        animator.send(.answerFailed)
      }
    }
    .onChange(of: panel.focusRequest) {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        bubbleFocused = true
      }
    }
    .onKeyPress(.escape) {
      bubbleFocused = false
      onReleaseKeyboard()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(
        "Pending requests: \(panel.requests.count)", bundle: .module,
        comment: "VoiceOver, on the palette of requests."))
    .accessibilityIdentifier("floating-request-panel")
  }

  // MARK: - Avatar

  private func avatar(count: Int) -> some View {
    AvatarView(
      images: model.avatarStudio?.currentImages ?? [:], expression: animator.expression,
      size: Self.avatarSize
    )
    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    .overlay(alignment: .topTrailing) {
      if panel.isCollapsed, count > 0 {
        Text(verbatim: "\(count)")
          .font(.caption.weight(.bold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(.orange))
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 3, coordinateSpace: .global)
        .onChanged { _ in
          let mouse = NSEvent.mouseLocation
          let start = dragStart ?? mouse
          if dragStart == nil { dragStart = mouse }
          onDrag(CGSize(width: mouse.x - start.x, height: mouse.y - start.y))
        }
        .onEnded { _ in
          dragStart = nil
          onDrag(nil)
        }
    )
    .onTapGesture { panel.toggleCollapsed() }
    .help(
      panel.isCollapsed
        ? Text("Show the requests", bundle: .module)
        : Text("Fold the requests", bundle: .module))
  }

  // MARK: - Bubble

  @ViewBuilder
  private func bubble(_ current: PendingRequest?) -> some View {
    if !panel.isCollapsed, current != nil || model.requestOutcome != nil {
      VStack(alignment: .leading, spacing: 6) {
        if let current {
          ScrollView {
            RequestCard(model: model, pending: current, isFocused: bubbleFocused)
          }
          .frame(maxHeight: maxBubbleHeight)
          .fixedSize(horizontal: false, vertical: true)
          .focusable()
          .focused($bubbleFocused)
          .onKeyPress(.leftArrow) {
            panel.show(offset: -1)
            return .handled
          }
          .onKeyPress(.rightArrow) {
            panel.show(offset: 1)
            return .handled
          }
          .id(current.id)
        }
        if let outcome = model.requestOutcome {
          outcomeLine(outcome)
        }
        footer
      }
      .padding(8)
      .frame(width: Self.bubbleWidth)
      .background(
        BubbleShape(tailLeading: !layout.bubbleLeading, tailBottom: layout.alignedBottom)
          .fill(.regularMaterial)
          .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
      )
      .overlay(
        BubbleShape(tailLeading: !layout.bubbleLeading, tailBottom: layout.alignedBottom)
          .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
      )
      .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.9)))
    }
  }

  private var footer: some View {
    HStack(spacing: 4) {
      if let position = panel.position, position.count > 1 {
        Button {
          panel.show(offset: -1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(position.index == 1)
        .accessibilityLabel(Text("Previous request", bundle: .module))
        Text(verbatim: "\(position.index) / \(position.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel(
            Text(
              "Request \(position.index) of \(position.count)", bundle: .module,
              comment: "VoiceOver, on the counter of the floating panel's bubble."))
        Button {
          panel.show(offset: 1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(position.index == position.count)
        .accessibilityLabel(Text("Next request", bundle: .module))
      }
      Spacer()
      Button {
        panel.toggleCollapsed()
      } label: {
        Image(systemName: "minus")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("-", modifiers: .command)
      .help(Text("Fold the requests", bundle: .module))
      .accessibilityLabel(Text("Fold the requests", bundle: .module))
    }
    .font(.caption)
  }

  private func outcomeLine(_ outcome: RequestOutcome) -> some View {
    Label {
      Text(
        AppModel.announcement(
          of: outcome.answer, outcome: outcome.outcome, sessionName: outcome.sessionName))
    } icon: {
      Image(
        systemName: outcome.outcome == .sent ? "checkmark.circle.fill" : "exclamationmark.circle")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(3)
    .task(id: outcome.id) {
      try? await Task.sleep(for: .seconds(outcome.outcome == .sent ? 2 : 5))
      model.dismissRequestOutcome(outcome.id)
    }
  }
}

/// A rounded bubble with a small tail toward the avatar.
struct BubbleShape: InsettableShape {
  var tailLeading: Bool
  var tailBottom: Bool
  var inset: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let rect = rect.insetBy(dx: inset, dy: inset)
    var path = Path(roundedRect: rect, cornerRadius: 14, style: .continuous)
    let tailY = tailBottom ? rect.maxY - 30 : rect.minY + 30
    let edge = tailLeading ? rect.minX : rect.maxX
    let tip = tailLeading ? edge - 8 : edge + 8
    path.move(to: CGPoint(x: edge, y: tailY - 8))
    path.addLine(to: CGPoint(x: tip, y: tailY))
    path.addLine(to: CGPoint(x: edge, y: tailY + 8))
    path.closeSubpath()
    return path
  }

  func inset(by amount: CGFloat) -> some InsettableShape {
    var shape = self
    shape.inset += amount
    return shape
  }
}
