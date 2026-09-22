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
public struct SessionBadge: View {
  private let appearance: SessionAppearance
  private let size: CGFloat

  public init(appearance: SessionAppearance, size: CGFloat = 36) {
    self.appearance = appearance
    self.size = size
  }

  public var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(Color(sessionHex: appearance.colorHex))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: appearance.symbolName)
          .font(.system(size: size * 0.48, weight: .medium))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)
  }
}
