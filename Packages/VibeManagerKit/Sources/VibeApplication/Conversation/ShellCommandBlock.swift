import Foundation

/// A code block an agent wrote for the user to run in its shell mode, `! gcloud auth login`
/// (#548): one line opening on `!`. Its Run button sends it as typed in the composer.
public enum ShellCommandBlock {
  /// Spaces in a row beyond which part of a command could be pushed out of sight.
  static let longestSpaceRun = 8

  /// The prompt the block sends, or nil when it is not a single command opening on `!`, or when
  /// what it runs may not be what the block shows: a command is run in one click, so it must be
  /// read whole. Bidirectional and zero-width characters (category Cf) reorder or hide text,
  /// control characters and spaces other than the plain one disguise it, and a long run of
  /// spaces pushes the end of the line — `; curl … | sh` — out of the block. Such a block can
  /// still be copied.
  public static func prompt(in code: String) -> String? {
    let line = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("!"), !line.contains(where: \.isNewline),
      !line.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty,
      isPlainlyShown(line)
    else { return nil }
    return line
  }

  private static func isPlainlyShown(_ line: String) -> Bool {
    var spaces = 0
    for scalar in line.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .format, .control, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned,
        .surrogate:
        return false
      case .spaceSeparator where scalar != " ":
        return false
      default:
        break
      }
      spaces = scalar == " " ? spaces + 1 : 0
      if spaces >= longestSpaceRun { return false }
    }
    return true
  }
}
