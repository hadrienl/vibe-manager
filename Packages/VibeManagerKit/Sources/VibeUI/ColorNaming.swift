import AppKit

/// A colour said in words — « bleu clair », « rouge foncé » — for VoiceOver, which would otherwise
/// read its hex code letter by letter (#232). Approximate on purpose: a name a person would give.
enum ColorNaming {
  /// The colour of `hex` (`#RRGGBB`), or `nil` when it is not one.
  static func name(ofHex hex: String) -> String? {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    let color = NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    return name(hue: hue * 360, saturation: saturation, brightness: brightness)
  }

  static func name(hue: Double, saturation: Double, brightness: Double) -> String {
    if brightness < 0.15 { return String(localized: "black", bundle: .module) }
    if saturation < 0.15 {
      if brightness > 0.9 { return String(localized: "white", bundle: .module) }
      return shade(String(localized: "gray", bundle: .module), saturation, brightness)
    }
    let base: String
    switch hue {
    case ..<15, 345...: base = String(localized: "red", bundle: .module)
    case ..<40:
      base =
        brightness < 0.6
        ? String(localized: "brown", bundle: .module) : String(localized: "orange", bundle: .module)
    case ..<65: base = String(localized: "yellow", bundle: .module)
    case ..<170: base = String(localized: "green", bundle: .module)
    case ..<200: base = String(localized: "teal", bundle: .module)
    case ..<255: base = String(localized: "blue", bundle: .module)
    case ..<290: base = String(localized: "purple", bundle: .module)
    default: base = String(localized: "pink", bundle: .module)
    }
    return shade(base, saturation, brightness)
  }

  private static func shade(_ base: String, _ saturation: Double, _ brightness: Double) -> String {
    if brightness < 0.45 {
      return String(
        localized: "dark \(base)", bundle: .module, comment: "A colour, darker: “dark blue”.")
    }
    if brightness > 0.8, saturation < 0.45 {
      return String(
        localized: "light \(base)", bundle: .module, comment: "A colour, paler: “light blue”.")
    }
    return base
  }
}
