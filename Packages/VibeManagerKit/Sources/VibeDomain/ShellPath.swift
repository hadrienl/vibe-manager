import Foundation

/// A path as a terminal reads it (#42): the one spelling of a file joined to a prompt, whether it
/// is typed into a session or handed to an agent at its launch.
public enum ShellPath {
  /// A path as Terminal.app writes a dropped file: every character a shell would read otherwise
  /// escaped with a backslash. An agent reads it as the path it is, and Claude Code attaches an
  /// image named that way. Accents and emoji are written as they are, like Terminal.app does, and
  /// the name is never normalized: the path stays exactly the one on disk.
  public static func escaped(_ path: String) -> String {
    let special = Set(" \t'\"\\$`!&*()[]{}|;<>?~#")
    var escaped = ""
    for character in path {
      if special.contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    return escaped
  }

  /// Whether a path can be written into the terminal: no control character anywhere in it. One
  /// could close a bracketed paste and type on its own.
  public static func isWritable(_ path: String) -> Bool {
    !path.unicodeScalars.contains {
      $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
    }
  }
}
