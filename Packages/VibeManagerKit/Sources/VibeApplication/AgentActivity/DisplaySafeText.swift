import Foundation

/// Text an agent wrote, made safe to show: nothing in it can hide what it says.
///
/// A control character, an escape sequence, a change of writing direction or a character of no
/// width can make a command read as another — `rm` passed off as `ls`. They are shown by name
/// instead of acting.
public enum DisplaySafeText {
  public static func visible(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x0A, 0x09:
        result.append(scalar)
      case 0x1B:
        result.append(contentsOf: "␛".unicodeScalars)
      case 0x00...0x1F:
        // Control Pictures: U+2400 is NUL, and the others follow in order.
        result.append(Unicode.Scalar(0x2400 + scalar.value) ?? "?")
      case 0x7F:
        result.append(contentsOf: "␡".unicodeScalars)
      case 0x80...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
        result.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
      default:
        result.append(scalar)
      }
    }
    return String(result)
  }
}
