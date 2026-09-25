import AppKit
import SwiftTerm

/// SwiftTerm's view, readable by VoiceOver.
///
/// SwiftTerm 1.20.0 exposes nothing to accessibility on the Mac: its service is a stub, and the
/// terminal was a silent rectangle. This makes it one read-only text area whose value is the
/// screen as it is now — the visible lines, not the scrollback — and whose label names the
/// session and what its agent is doing. Output is never announced as it arrives: an agent writing
/// fifty lines a second would make VoiceOver unusable. Read Last Output (⌃⌥⌘O) says the last lines
/// on demand.
public final class AccessibleTerminalView: TerminalView {
  /// "Terminal — <session> — <agent state>", set by the surface.
  public var accessibilityTitle = String(localized: "Terminal", bundle: .module)

  public override func isAccessibilityElement() -> Bool { true }

  public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  public override func accessibilityRoleDescription() -> String? {
    String(localized: "terminal", bundle: .module, comment: "What VoiceOver calls the element.")
  }

  public override func accessibilityLabel() -> String? { accessibilityTitle }

  public override func accessibilityValue() -> Any? {
    TerminalText.visibleScreen(of: getTerminal())
  }

  public override func isAccessibilityFocused() -> Bool {
    window?.firstResponder === self
  }

  public override func accessibilityHelp() -> String? {
    String(
      localized:
        "Read Last Output, Control-Option-Command-O, reads the last lines the agent wrote.",
      bundle: .module, comment: "Read Last Output is a command of the View menu.")
  }
}

/// Text out of a terminal, for people rather than for a terminal.
public enum TerminalText {
  /// The screen's lines, trailing blanks and trailing empty lines removed.
  public static func visibleScreen(of terminal: Terminal) -> String {
    var lines: [String] = []
    for row in 0..<terminal.rows {
      let text = terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
      // Cells never written read as NUL, which is nothing to say.
      lines.append(
        text.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces))
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.joined(separator: "\n")
  }

  /// The last `count` lines that say something, out of what a program wrote: escape sequences
  /// removed, a line rewritten by carriage returns reduced to what it ended as.
  public static func lastLines(of bytes: [UInt8], count: Int) -> [String] {
    let plain = stripEscapes(String(decoding: bytes.suffix(64 * 1024), as: UTF8.self))
    var lines: [String] = []
    var line = String.UnicodeScalarView()
    var scalars = Array(plain.unicodeScalars)[...]
    func finish() {
      let trimmed = String(line).trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { lines.append(trimmed) }
      line = String.UnicodeScalarView()
    }
    // Scalars, not characters: `\r\n` is one `Character`, and neither `\r` nor `\n`.
    while let scalar = scalars.popFirst() {
      switch scalar {
      case "\n":
        finish()
      case "\r":
        if scalars.first == "\n" {
          scalars.removeFirst()
          finish()
        } else {
          // A carriage return starts the line over: what follows is what shows.
          line = String.UnicodeScalarView()
        }
      default:
        line.append(scalar)
      }
    }
    finish()
    return Array(lines.suffix(count))
  }

  /// CSI, OSC and two-character escape sequences, and the other control characters but the line
  /// endings, removed.
  static func stripEscapes(_ text: String) -> String {
    var output = String.UnicodeScalarView()
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case "\u{1B}":
        guard let next = scalars.next() else { break }
        if next == "[" {
          // CSI: parameters and intermediates, up to a final byte in @…~.
          while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {}
        } else if next == "]" {
          // OSC: up to BEL or ST.
          var previous: Unicode.Scalar?
          while let byte = scalars.next() {
            if byte == "\u{07}" || (previous == "\u{1B}" && byte == "\\") { break }
            previous = byte
          }
        }
      case "\n", "\r", "\t":
        output.append(scalar)
      default:
        if scalar.value >= 0x20, scalar.value != 0x7F { output.append(scalar) }
      }
    }
    return String(output)
  }
}
