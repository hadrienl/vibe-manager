import Foundation
import VibeDomain

/// What a drop hands to a session once it has been read (#42): a file on disk, or text.
public enum DropPayload: Hashable, Sendable {
  case file(URL)
  case text(String)
}

/// How dropped files and text are typed into a session's terminal (#42).
///
/// The one encoder of paths: the composer's attachments, a drop on the terminal and a drop on a
/// row of the sidebar all write a file the same way, as Terminal.app writes one dropped on it.
public enum PathInsertion {
  /// A path as Terminal.app writes a dropped file: see `ShellPath.escaped(_:)`.
  public static func shellEscaped(_ path: String) -> String {
    ShellPath.escaped(path)
  }

  /// Whether a path can be written into the terminal: see `ShellPath.isWritable(_:)`.
  public static func isWritablePath(_ path: String) -> Bool {
    ShellPath.isWritable(path)
  }

  /// The words a drop types, in the order of the drop, and what could not be written.
  ///
  /// A file is its absolute path, escaped. Text is written as it is — it is not a path — but
  /// without a control character, so that it can neither close the paste nor send a sequence of
  /// its own; on one line, since a line break typed outside a bracketed paste runs the line.
  public static func words(
    for payloads: [DropPayload]
  ) -> (words: [String], rejected: [DropPayload]) {
    var words: [String] = []
    var rejected: [DropPayload] = []
    for payload in payloads {
      switch payload {
      case .file(let url):
        let path = url.standardizedFileURL.path
        if isWritablePath(path) {
          words.append(shellEscaped(path))
        } else {
          rejected.append(payload)
        }
      case .text(let text):
        let line = PromptEncoding.sanitized(text)
          .split(whereSeparator: { $0 == "\n" || $0 == "\t" })
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { words.append(line) }
      }
    }
    return (words, rejected)
  }

  /// The bytes a drop types into a terminal, never followed by Return: the words separated by a
  /// space, then a space, as Terminal.app does, so that what is typed next does not stick to the
  /// last path. Inside a bracketed paste when the program asked for one, so that an agent takes
  /// the paths as pasted — which is how Claude Code recognizes an image. Empty when nothing can be
  /// written.
  public static func terminalBytes(for payloads: [DropPayload], bracketed: Bool) -> [UInt8] {
    let words = words(for: payloads).words
    guard !words.isEmpty else { return [] }
    let body = Array((words.joined(separator: " ") + " ").utf8)
    guard bracketed else { return body }
    return Array("\u{1B}[200~".utf8) + body + Array("\u{1B}[201~".utf8)
  }
}
