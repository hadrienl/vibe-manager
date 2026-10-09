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
  /// A colour the glass takes, and a border it keeps: a state not to miss, as a shell command.
  var tint: Color?
  var isInteractive = false
  var shadowRadius: CGFloat = 0
  var shadowOpacity: Double = 0
  var shadowY: CGFloat = 1

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .glassEffect(glass, in: shape)
        .overlay {
          if tint != nil { shape.stroke(border, lineWidth: lineWidth) }
        }
    } else {
      content
        .background(fill, in: shape)
        .overlay(shape.stroke(border, lineWidth: lineWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
    }
  }

  @available(macOS 26, *)
  private var glass: Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    return glass.interactive(isInteractive)
  }
}
