import SwiftUI

extension View {
  /// A tooltip shown a quarter of a second after the pointer comes over the view, above it,
  /// rather than the system's, which waits seconds (#352). Said to VoiceOver as the view's hint.
  public func instantTooltip(_ text: Text) -> some View {
    modifier(InstantTooltip(text: text))
  }
}

private struct InstantTooltip: ViewModifier {
  let text: Text
  @State private var isShown = false
  @State private var appearing: Task<Void, Never>?
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
      // Above the view, from its leading edge: the composer's controls sit at its left.
      .overlay(alignment: .topLeading) {
        if isShown {
          text
            .font(.callout)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .alignmentGuide(.top) { $0[.bottom] + 6 }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
      }
      .zIndex(isShown ? 1 : 0)
      .accessibilityHint(text)
  }
}
