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
      let gray = String(localized: "gray", bundle: .module, comment: "A colour, said by VoiceOver.")
      if brightness < 0.45 { return dark(gray) }
      return brightness > 0.8 ? light(gray) : gray
    }
    let base = base(hue: hue, brightness: brightness)
    // « très foncé » for the truly dark only; « foncé » below 82 % of the full brightness.
    if brightness < 0.45 {
      return String(
        localized: "very dark \(base)", bundle: .module,
        comment: "A colour, much darker: “very dark blue”.")
    }
    if brightness < 0.82 { return dark(base) }
    return brightness >= 0.85 && saturation < 0.45 ? light(base) : base
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
    // The pure hues — 60° yellow, 240° blue, 300° magenta — fall in their own name, not the next.
    case ..<65:
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
    case ..<245:
      String(localized: "blue", bundle: .module, comment: "A colour, said by VoiceOver.")
    case ..<275:
      String(
        localized: "indigo", bundle: .module,
        comment: "A colour, said by VoiceOver: between blue and violet.")
    case ..<305:
      String(localized: "purple", bundle: .module, comment: "A colour, said by VoiceOver.")
    default:
      String(
        localized: "pink", bundle: .module,
        comment: "A colour, said by VoiceOver: the flower's, not the wine's.")
    }
  }

  private static func dark(_ base: String) -> String {
    String(localized: "dark \(base)", bundle: .module, comment: "A colour, darker: “dark blue”.")
  }

  private static func light(_ base: String) -> String {
    String(localized: "light \(base)", bundle: .module, comment: "A colour, paler: “light blue”.")
  }
}
