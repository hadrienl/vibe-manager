import VibeDomain

/// A colour said in words — « bleu clair », « rouge foncé » — for VoiceOver, which would otherwise
/// read its hex code letter by letter (#232). Approximate on purpose: a name a person would give,
/// fine enough that the neighbouring shades of a palette do not all sound alike.
enum ColorNaming {
  /// The colour of `hex`, or `nil` when it is not one.
  static func name(ofHex hex: String) -> String? {
    guard let (hue, saturation, brightness) = SessionAppearancePalette.hsb(of: hex) else {
      return nil
    }
    return name(hue: hue * 360, saturation: saturation, brightness: brightness)
  }

  static func name(hue: Double, saturation: Double, brightness: Double) -> String {
    if brightness < 0.15 {
      return String(localized: "black", bundle: .module, comment: "A colour, said by VoiceOver.")
    }
    if saturation < 0.15 {
      if brightness > 0.9 {
        return String(localized: "white", bundle: .module, comment: "A colour, said by VoiceOver.")
      }
      return shade(
        String(localized: "gray", bundle: .module, comment: "A colour, said by VoiceOver."),
        saturation, brightness)
    }
    return shade(base(hue: hue, brightness: brightness), saturation, brightness)
  }

  private static func base(hue: Double, brightness: Double) -> String {
    switch hue {
    case ..<15, 345...:
      String(localized: "red", bundle: .module, comment: "A colour, said by VoiceOver.")
    case ..<40 where brightness < 0.6:
      String(localized: "brown", bundle: .module, comment: "A colour, said by VoiceOver.")
    case ..<40:
      String(
        localized: "orange", bundle: .module, comment: "A colour, said by VoiceOver: the fruit's.")
    case ..<60:
      String(localized: "yellow", bundle: .module, comment: "A colour, said by VoiceOver.")
    case ..<90:
      String(
        localized: "yellow-green", bundle: .module,
        comment: "A colour, said by VoiceOver: between yellow and green.")
    case ..<125:
      String(localized: "green", bundle: .module, comment: "A colour, said by VoiceOver.")
    case ..<150:
      String(
        localized: "emerald", bundle: .module,
        comment: "A colour, said by VoiceOver: a green leaning to blue.")
    case ..<200:
      String(
        localized: "teal", bundle: .module,
        comment: "A colour, said by VoiceOver: between green and blue.")
    case ..<240:
      String(localized: "blue", bundle: .module, comment: "A colour, said by VoiceOver.")
    case ..<275:
      String(
        localized: "indigo", bundle: .module,
        comment: "A colour, said by VoiceOver: between blue and violet.")
    case ..<300:
      String(localized: "purple", bundle: .module, comment: "A colour, said by VoiceOver.")
    default:
      String(
        localized: "pink", bundle: .module,
        comment: "A colour, said by VoiceOver: the flower's, not the wine's.")
    }
  }

  /// « foncé » below 85 % of the full brightness, « très foncé » below 65 % — the deeper rows
  /// of a palette — « clair » for a pale tint.
  private static func shade(_ base: String, _ saturation: Double, _ brightness: Double) -> String {
    if brightness < 0.65 {
      return String(
        localized: "very dark \(base)", bundle: .module,
        comment: "A colour, much darker: “very dark blue”.")
    }
    if brightness < 0.85 {
      return String(
        localized: "dark \(base)", bundle: .module, comment: "A colour, darker: “dark blue”.")
    }
    if saturation < 0.45 {
      return String(
        localized: "light \(base)", bundle: .module, comment: "A colour, paler: “light blue”.")
    }
    return base
  }
}
