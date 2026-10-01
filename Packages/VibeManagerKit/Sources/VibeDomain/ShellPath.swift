import Foundation

/// A path as a terminal reads it (#42): the one spelling of a file joined to a prompt, whether it
/// is typed into a session or handed to an agent at its launch.
public enum ShellPath {
  /// A path as Terminal.app writes a dropped file: every character a shell would read otherwise
  /// escaped with a backslash. An agent reads it as the path it is, and Claude Code attaches an
  /// image named that way. Accents and emoji are written as they are, like Terminal.app does, and
  /// the name is never normalized: the path stays exactly the one on disk.
  public static func escaped(_ path: String) -> String {
    var escaped = ""
    for character in path {
      if specialCharacters.contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    return escaped
  }

  /// The paths `escaped` wrote at the end of `text`, one after the other, and the text before them
  /// (#209): the files the composer joined to a prompt. Only absolute paths count, separated by
  /// spaces; a backslash takes the character after it as it is. Nil when `text` does not end with
  /// such a path.
  public static func trailingPaths(in text: String) -> (body: Substring, paths: [String])? {
    var paths: [String] = []
    var end = text.endIndex
    while let (start, path) = lastWord(in: text[..<end]), path.hasPrefix("/"), path.count > 1 {
      paths.insert(path, at: 0)
      end = start
      // The words are separated by one space; whatever else stands before the first is the body.
      guard end > text.startIndex, text[text.index(before: end)] == " " else { break }
      end = text.index(before: end)
    }
    guard !paths.isEmpty else { return nil }
    return (text[..<end], paths)
  }

  /// The last word of `text`, unescaped, and where it starts: up to the space before it that no
  /// backslash escapes. Nil when it holds a character `escaped` would have escaped bare, or when
  /// it ends on a lone backslash. Read backwards from the end: a long text is never copied.
  private static func lastWord(in text: Substring) -> (String.Index, String)? {
    guard let last = text.last, !last.isWhitespace else { return nil }
    var start = text.endIndex
    while start > text.startIndex {
      let before = text.index(before: start)
      if text[before] == " " || text[before] == "\n" || text[before] == "\t" {
        // A separator unless an odd number of backslashes escapes it.
        var backslashes = 0
        var index = before
        while index > text.startIndex, text[text.index(before: index)] == "\\" {
          backslashes += 1
          index = text.index(before: index)
        }
        if backslashes % 2 == 0 { break }
      }
      start = before
    }
    var word = ""
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if character == "\\" {
        let next = text.index(after: index)
        guard next < text.endIndex else { return nil }
        word.append(text[next])
        index = text.index(after: next)
      } else {
        if specialCharacters.contains(character) || character == "\n" { return nil }
        word.append(character)
        index = text.index(after: index)
      }
    }
    return (start, word)
  }

  private static let specialCharacters = Set(" \t'\"\\$`!&*()[]{}|;<>?~#")

  /// Whether a path can be written into the terminal: no control character anywhere in it. One
  /// could close a bracketed paste and type on its own.
  public static func isWritable(_ path: String) -> Bool {
    !path.unicodeScalars.contains {
      $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
    }
  }
}
