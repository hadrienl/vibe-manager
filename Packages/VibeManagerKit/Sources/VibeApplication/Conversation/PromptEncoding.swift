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

  /// What the text is for an agent with the given shell mode (#188): a command when it opens on
  /// `!`, a message otherwise. Without a shell mode, `!` is text like any other.
  public func kind(shell: ShellEntry?) -> PromptKind {
    guard shell != nil, text.hasPrefix("!") else { return .message }
    // A tab typed is taken for a key — completion — not text: the command is the one typed.
    return .shell(
      command: PromptEncoding.sanitized(String(text.dropFirst()))
        .replacingOccurrences(of: "\t", with: "    ")
        .trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// The message the agent reads: `\!` opening it stands for a `!` that is not a command, for an
  /// agent with a shell mode.
  public func messageText(shell: ShellEntry?) -> String {
    guard shell != nil, text.hasPrefix(PromptKind.literalBang) else { return text }
    return String(text.dropFirst())
  }
}

/// What a prompt sent from the composer is: a message to the agent, or a command for its shell.
public enum PromptKind: Hashable, Sendable {
  case message
  case shell(command: String)

  /// Opening a draft, it sends the message "!…" rather than a command.
  public static let literalBang = "\\!"

  public var isShell: Bool {
    if case .shell = self { return true }
    return false
  }
}

/// The bytes a prompt becomes in the agent's terminal (#38).
///
/// The conversation view writes to the agent exactly as a keyboard would, and by no other road:
/// the terminal stays the one channel to it (ADR 0025). The text, typed or pasted as the agent
/// wants it, then the key that sends it, written apart so that the TUI has seen the text end.
public enum PromptEncoding {
  public struct Keystrokes: Hashable, Sendable {
    /// What writes the prompt, in order, `interval` apart.
    public let writes: [[UInt8]]
    public let interval: Duration
    public let submit: [UInt8]
    /// Between the first write and the second, when that wait is not `interval`: the shell mode's
    /// trigger has to be taken before the command follows.
    public var firstInterval: Duration? = nil

    /// How long to wait before the write at `index`.
    public func delay(before index: Int) -> Duration {
      guard index > 0 else { return .zero }
      return index == 1 ? firstInterval ?? interval : interval
    }
  }

  public static func keystrokes(
    for submission: PromptSubmission, format: AgentPromptFormat, whileWorking: Bool
  ) -> Keystrokes {
    let submit = whileWorking ? format.queueKey : format.submitKey
    if let shell = format.shellEntry, case .shell(let command) = submission.kind(shell: shell) {
      return Keystrokes(
        writes: [shell.trigger] + chunks(of: command, size: shell.chunkSize),
        interval: shell.chunkDelay, submit: submit, firstInterval: shell.switchDelay)
    }
    let text = submission.messageText(shell: format.shellEntry)
    var body = sanitized(text).trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("!"), let shell = format.shellEntry { body = shell.messageGuard + body }
    // A file named with a control character could close the paste and type on its own: such a
    // path is not written at all.
    let paths = submission.attachments.map(\.path).filter(PathInsertion.isWritablePath)
      .map(PathInsertion.shellEscaped).joined(separator: " ")
    let separator = body.isEmpty || paths.isEmpty ? "" : " "
    switch format.textEntry {
    case .plain:
      return Keystrokes(
        writes: [Array((body + separator + paths).utf8)], interval: .zero, submit: submit)
    case .bracketedPaste:
      return Keystrokes(
        writes: [bracketed(body + separator + paths)], interval: .zero, submit: submit)
    case .typed(let chunkSize, let chunkDelay):
      // A `!` typed first switches Claude Code to its shell, even pasted alone: pasted with the
      // rest, it stays text.
      if body.hasPrefix("!") {
        return Keystrokes(
          writes: [bracketed(body + separator + paths)], interval: .zero, submit: submit)
      }
      // A tab typed is taken for a key, not text. The paths stay pasted: an image is joined to
      // the prompt only from a pasted path.
      var writes = chunks(of: body.replacingOccurrences(of: "\t", with: "    "), size: chunkSize)
      if !paths.isEmpty { writes.append(bracketed(separator + paths)) }
      return Keystrokes(writes: writes, interval: chunkDelay, submit: submit)
    }
  }

  private static func bracketed(_ text: String) -> [UInt8] {
    Array("\u{1B}[200~".utf8) + Array(text.utf8) + Array("\u{1B}[201~".utf8)
  }

  /// The UTF-8 of `text` in pieces of at most `size` bytes, never splitting a character.
  private static func chunks(of text: String, size: Int) -> [[UInt8]] {
    var chunks: [[UInt8]] = []
    var current: [UInt8] = []
    for scalar in text.unicodeScalars {
      let bytes = Array(String(scalar).utf8)
      if !current.isEmpty && current.count + bytes.count > size {
        chunks.append(current)
        current = []
      }
      current += bytes
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
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
}
