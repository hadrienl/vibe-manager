import SwiftUI
import VibeDomain

extension Color {
  /// The stored identity colour. A value that cannot be read falls back to grey rather than to
  /// a colour that would claim a choice: a session must stay visible even if its record is odd.
  public init(sessionHex hex: String) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else {
      self = .gray
      return
    }

    let hasAlpha = digits.count == 8
    let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1

    self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }
}

/// The identity of a session, drawn once and reused: the live preview in the creation sheet and
/// the sidebar row are the same view, so what the user previews is what they get.
///
/// A project icon, when the session has one and its image could be read, sits on a neutral
/// ground; otherwise the symbol is drawn on the session's colour.
public struct SessionBadge: View {
  private let appearance: SessionAppearance
  private let icon: NSImage?
  private let size: CGFloat

  public init(appearance: SessionAppearance, icon: NSImage? = nil, size: CGFloat = 36) {
    self.appearance = appearance
    self.icon = appearance.iconID == nil ? nil : icon
    self.size = size
  }

  public var body: some View {
    Group {
      if let icon {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
          .fill(.quaternary)
          .overlay {
            Image(nsImage: icon)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .padding(size * 0.12)
          }
      } else {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
          .fill(Color(sessionHex: appearance.colorHex))
          .overlay {
            Image(systemName: appearance.symbolName)
              .font(.system(size: size * 0.48, weight: .medium))
              .foregroundStyle(.white)
          }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
