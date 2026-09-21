import Foundation

/// Shape checks shared by every provider that puts a user supplied value on a command line.
///
/// Arguments already travel as an array, so this is not about escaping: it is about refusing a
/// value that would be read as an option, or that carries a newline no CLI expects.
public enum AgentArgumentToken {
  public static func isWellFormed(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("-") else { return false }
    return !value.unicodeScalars.contains { scalar in
      CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.controlCharacters.contains(scalar)
    }
  }

  /// A token that must not be read as a path, so it can never escape the directory it names.
  public static func isWellFormedIdentifier(_ value: String) -> Bool {
    isWellFormed(value) && !value.contains("/")
  }
}
