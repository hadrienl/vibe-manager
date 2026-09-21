import Foundation

/// The closed set of identities a session may wear, and the rule that picks one for free.
///
/// Closed on purpose: every pair in here is checked for contrast in both appearances, which an
/// arbitrary value picked in a colour well could not promise. Storage still accepts any valid
/// hex — a session written by a future version must not fail to load here.
public enum SessionAppearanceCatalog {
  public static let symbolNames = [
    "terminal",
    "wrench.and.screwdriver",
    "doc.text",
    "bolt",
    "ladybug",
    "flask",
    "shippingbox",
    "point.3.connected.trianglepath.dotted",
  ]

  public static let colorHexValues = [
    "#5E5CE6",
    "#0B63E5",
    "#0F7B76",
    "#1E7F4D",
    "#A65B00",
    "#B42318",
    "#7A3DB8",
    "#0A6E8A",
  ]

  /// Worn while the session has no name yet: grey says "not decided" where a colour would claim
  /// a choice the user has not made.
  public static let placeholder = SessionAppearance(symbolName: "terminal", colorHex: "#8E8E96")

  /// The identity a name gets when the user picks nothing.
  ///
  /// Derived rather than random so the preview stays put while typing continues, and so the same
  /// name always looks the same. The hash is written out rather than taken from `Hasher`, whose
  /// seed changes at every launch: an identity that moved between two runs would be worse than
  /// no identity at all.
  public static func derived(forName name: String) -> SessionAppearance {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return placeholder }

    let hash = fnv1a(key)
    let symbol = symbolNames[Int(hash % UInt64(symbolNames.count))]
    let color = colorHexValues[
      Int((hash / UInt64(symbolNames.count)) % UInt64(colorHexValues.count))
    ]
    return SessionAppearance(symbolName: symbol, colorHex: color)
  }

  public static func contains(_ appearance: SessionAppearance) -> Bool {
    symbolNames.contains(appearance.symbolName)
      && colorHexValues.contains(appearance.colorHex.uppercased())
  }

  private static func fnv1a(_ value: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }
}
