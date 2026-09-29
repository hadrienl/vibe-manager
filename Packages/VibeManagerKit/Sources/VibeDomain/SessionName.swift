import Foundation

/// What a session may be called (#183): one rule, for the name typed at creation and for a rename.
///
/// Checked where a name comes in, never in `WorkSession.validate()`: a session stored with a longer
/// name — by an earlier version, or by hand — must still load and still take its other changes.
public enum SessionName {
  /// The longest name accepted, in characters as the user counts them: an emoji is one.
  public static let maximumLength = 120

  /// One line, without the spaces around it: a line break or a tab pasted into a one-line field
  /// becomes a space.
  public static func normalized(_ raw: String) -> String {
    let flattened = raw.unicodeScalars.map { scalar -> String in
      CharacterSet.newlines.contains(scalar) || scalar == "\t" ? " " : String(scalar)
    }.joined()
    return flattened.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The name to store, or why it is refused.
  public static func validated(_ raw: String) -> Result<String, SessionDraftIssue> {
    let name = normalized(raw)
    if name.isEmpty { return .failure(.nameMissing) }
    if name.count > maximumLength { return .failure(.nameTooLong) }
    return .success(name)
  }

  /// Cut at the last word that fits, "…" included, so that a name never ends in half a word.
  public static func shortened(_ line: String, to length: Int = maximumLength) -> String {
    guard line.count > length else { return line }
    let head = line.prefix(length - 1)
    let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
    return cut.trimmingCharacters(in: .whitespaces) + "…"
  }
}
