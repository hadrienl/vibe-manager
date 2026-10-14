import SwiftUI

extension View {
  /// A tooltip shown a quarter of a second after the pointer comes over the view, rather than the
  /// system's, which waits seconds (#352): a glass bubble above the view, its arrow on it. Said to
  /// VoiceOver as the view's hint.
  public func instantTooltip(_ text: Text) -> some View {
    modifier(InstantTooltip(text: text))
  }
}

private struct InstantTooltip: ViewModifier {
  let text: Text
  @State private var isShown = false
  @State private var appearing: Task<Void, Never>?
  /// The view's frame in the window, to keep the bubble off the window's leading edge.
  @State private var frame = CGRect.zero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .onHover { isInside in
        appearing?.cancel()
        guard isInside else {
          isShown = false
          return
        }
        appearing = Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled else { return }
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isShown = true }
        }
      }
      .onDisappear {
        appearing?.cancel()
        isShown = false
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        frame = $0
      }
      // Centred over the view; near the window's leading edge, the bubble sits against the edge and
      // only its arrow stays over the view.
      .overlay(alignment: .top) {
        if isShown {
          let shift = TooltipBubble.shift(forViewAt: frame)
          TooltipBubble(text: text, arrowX: TooltipBubble.width / 2 - shift)
            .alignmentGuide(.top) { $0[.bottom] + 3 }
            .offset(x: shift)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
      }
      .zIndex(isShown ? 1 : 0)
      .accessibilityHint(text)
  }
}

private struct TooltipBubble: View {
  static let width: CGFloat = 250
  /// Kept between the bubble and the window's leading edge.
  static let margin: CGFloat = 8

  let text: Text
  let arrowX: CGFloat

  /// How far right of centred the bubble goes for a view at `frame` to keep in the window.
  static func shift(forViewAt frame: CGRect) -> CGFloat {
    max(0, margin - (frame.midX - width / 2))
  }

  var body: some View {
    let shape = TooltipBubbleShape(arrowX: arrowX)
    text
      .font(.callout)
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: Self.width - 22, alignment: .leading)
      .padding(.horizontal, 11)
      .padding(.top, 7)
      .padding(.bottom, 7 + TooltipBubbleShape.arrowLength)
      .modifier(TooltipGlass(shape: shape))
  }
}

/// Liquid glass on macOS 26; before, the material popovers use, with their edge.
private struct TooltipGlass<S: Shape>: ViewModifier {
  let shape: S

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content
        .background(.regularMaterial, in: shape)
        .overlay { shape.stroke(.separator) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  }
}

/// A rounded rectangle and its arrow under it, in one outline so the edge runs along the arrow
/// rather than across its base. The arrow takes the bottom `arrowLength` of the rect.
struct TooltipBubbleShape: Shape {
  static let arrowLength: CGFloat = 6
  let arrowX: CGFloat
  var cornerRadius: CGFloat = 9

  func path(in rect: CGRect) -> Path {
    let length = Self.arrowLength
    let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - length)
    let radius = min(cornerRadius, body.width / 2, body.height / 2)
    let x = min(max(rect.minX + arrowX, body.minX + radius + length), body.maxX - radius - length)
    var path = Path()
    path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
    path.addLine(to: CGPoint(x: x + length, y: body.maxY))
    path.addLine(to: CGPoint(x: x, y: rect.maxY))
    path.addLine(to: CGPoint(x: x - length, y: body.maxY))
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
    path.closeSubpath()
    return path
  }
}
