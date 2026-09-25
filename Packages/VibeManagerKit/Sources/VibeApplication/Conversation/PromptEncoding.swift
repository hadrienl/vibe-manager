import Foundation

/// A prompt written in the conversation view, with the files the user joined to it.
public struct PromptSubmission: Hashable, Sendable {
  public var text: String
  public var attachments: [URL]

  public init(text: String, attachments: [URL] = []) {
    self.text = text
    self.attachments = attachments
  }

  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
  }
}

/// The bytes a prompt becomes in the agent's terminal (#38).
///
/// The conversation view writes to the agent exactly as a keyboard would, and by no other road:
/// the terminal stays the one channel to it (ADR 0023). A paste, then the key that sends it,
/// written apart so that the TUI has seen the paste end.
public enum PromptEncoding {
  public struct Keystrokes: Hashable, Sendable {
    public let paste: [UInt8]
    public let submit: [UInt8]
  }

  public static func keystrokes(
    for submission: PromptSubmission, format: AgentPromptFormat, whileWorking: Bool
  ) -> Keystrokes {
    var body = sanitized(submission.text).trimmingCharacters(in: .whitespacesAndNewlines)
    // A file named with a control character could close the paste and type on its own: such a
    // path is not written at all.
    let paths = submission.attachments.map(\.path).filter(isWritablePath).map(shellEscaped)
    if !paths.isEmpty {
      body += (body.isEmpty ? "" : " ") + paths.joined(separator: " ")
    }
    var paste = Array(body.utf8)
    if format.usesBracketedPaste {
      paste = Array("\u{1B}[200~".utf8) + paste + Array("\u{1B}[201~".utf8)
    }
    return Keystrokes(paste: paste, submit: whileWorking ? format.queueKey : format.submitKey)
  }

  /// Every control character but the line break and the tab is dropped, Escape first of all: a
  /// text pasted into the composer must neither close the bracketed paste nor send a sequence of
  /// its own to the terminal.
  public static func sanitized(_ text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return String(
      String.UnicodeScalarView(
        normalized.unicodeScalars.filter { scalar in
          if scalar == "\n" || scalar == "\t" { return true }
          return
            !(scalar.value < 0x20 || scalar.value == 0x7F
            || (0x80...0x9F).contains(scalar.value))
        }))
  }

  /// Whether a path can be written into the terminal: no control character anywhere in it.
  public static func isWritablePath(_ path: String) -> Bool {
    !path.unicodeScalars.contains {
      $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
    }
  }

  /// A path as Terminal.app writes a dropped file: every character a shell would read otherwise
  /// escaped with a backslash. An agent reads it as the path it is, and Claude Code attaches an
  /// image named that way.
  public static func shellEscaped(_ path: String) -> String {
    let special = Set(" \t'\"\\$`!&*()[]{}|;<>?~#")
    var escaped = ""
    for character in path {
      if special.contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    return escaped
  }
}
