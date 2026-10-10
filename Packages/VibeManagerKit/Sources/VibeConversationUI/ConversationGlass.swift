import SwiftUI

/// What floats over the end of the conversation — the composer and what goes with it — is glass
/// on macOS 26, the messages blurred through it as they scroll under (#359). Before, the theme's
/// fill and its border.
struct ConversationGlass<S: Shape>: ViewModifier {
  let shape: S
  /// The fill before macOS 26.
  let fill: Color
  let border: Color
  var lineWidth: CGFloat = 1
  /// A colour the glass takes: a state not to miss, as a shell command.
  var tint: Color?
  var isInteractive = false
  var shadowRadius: CGFloat = 0
  var shadowOpacity: Double = 0
  var shadowY: CGFloat = 1
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .glassEffect(glass, in: shape)
        .overlay {
          if keepsBorder { shape.stroke(border, lineWidth: lineWidth) }
        }
    } else {
      let filled =
        content
        .background(fill, in: shape)
        .overlay(shape.stroke(border, lineWidth: lineWidth))
      if shadowOpacity > 0 {
        filled.shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
      } else {
        filled
      }
    }
  }

  /// Glass draws its own edge. The border stays for a tinted state, as its outline, and for
  /// increased contrast, where glass alone is too faint an edge.
  private var keepsBorder: Bool { tint != nil || contrast == .increased }

  @available(macOS 26, *)
  private var glass: Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    return glass.interactive(isInteractive)
  }
}

/// A line said over the end of the conversation — the agent at work, a session stopped — on glass
/// on macOS 26, where the messages scroll under it rather than under a plain footer. Before, as is.
struct StatusGlass: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    } else {
      content
    }
  }
}
