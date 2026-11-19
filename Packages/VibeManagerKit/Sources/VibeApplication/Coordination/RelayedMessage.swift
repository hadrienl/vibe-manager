import Foundation

/// A message a session was sent by Vibe Manager or by its coordinator rather than typed by the
/// user, read back from its transcript so that the conversation shows who wrote it.
///
/// Read from the text alone: the mark it opens with is all a transcript keeps of its author.
public struct RelayedMessage: Equatable, Sendable {
  public enum Sender: Equatable, Sendable {
    /// Vibe Manager, telling a coordinator what its children did.
    case application
    /// A coordinator, writing to one of its children; its name.
    case coordinator(String)
  }

  public let sender: Sender
  /// What it says, in Markdown, without its mark. Vibe Manager's words are shown as they were
  /// written — a command, a question —, and a child is named in bold, without the identifier the
  /// coordinator was given; a coordinator's are its own Markdown.
  public let body: String
  /// The children it names, in order and once each: what it is about, folded.
  public let children: [String]

  /// `nil` for what the user wrote — the coordination prefaces in front of their words included.
  public init?(_ text: String) {
    // Most prompts are the user's: told apart before anything is copied.
    guard text.drop(while: \.isWhitespace).first == "[" else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CoordinatorInstructions.userText(of: trimmed) == nil,
      // A preface alone: the user's message was only files.
      trimmed != CoordinatorInstructions.turnedOn, trimmed != CoordinatorInstructions.turnedOff
    else { return nil }
    if trimmed.hasPrefix(CoordinationPolicy.coordinatorMark) {
      let rest = trimmed.dropFirst(CoordinationPolicy.coordinatorMark.count)
      // Without its space: a message with no words was trimmed of it.
      guard let close = rest.range(of: CoordinationPolicy.coordinatorMarkClose) else { return nil }
      sender = .coordinator(String(rest[..<close.lowerBound]))
      children = []
      body = rest[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      return
    }
    guard trimmed.hasPrefix(CoordinatorInstructions.applicationMark) else { return nil }
    let rest = trimmed.dropFirst(CoordinatorInstructions.applicationMark.count)
      .trimmingCharacters(in: .whitespaces)
    var lines = rest.split(separator: "\n", omittingEmptySubsequences: false)
    // « 2 events: », the title of Vibe Manager's only message of its own: the list says as much.
    // Without it, words the user pasted after the mark.
    guard let first = lines.first, first.wholeMatch(of: /\d+ events?:/) != nil else { return nil }
    lines.removeFirst()
    sender = .application
    body = lines.map { Self.shown(String($0)) }.joined(separator: "\n")
    var named: [String] = []
    for match in rest.matches(of: Self.child()) where !named.contains(String(match.1)) {
      named.append(String(match.1))
    }
    children = named
  }

  /// A prompt's, unless files came with it: only the user sends files. A path the transcript
  /// reader joined from the text itself is not one: a coordinator's message may end with one.
  public init?(_ text: String, attachments: [MessageAttachment]) {
    guard attachments.allSatisfy(\.isWrittenInText) else { return nil }
    self.init(text)
  }

  /// « “name” (identifier) », as Vibe Manager names a child to its coordinator.
  private static func child() -> Regex<(Substring, Substring)> {
    /“([^“”\n]+?)” \([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\)/
  }

  /// A line of Vibe Manager's in Markdown that shows it as written: an event's list mark kept,
  /// each child's name in bold. A line that goes on a child's question loses its indent, which
  /// Markdown would take for code.
  static func shown(_ line: String) -> String {
    var result = ""
    var rest = Substring(line)
    if rest.hasPrefix("- ") {
      result = "- "
      rest = rest.dropFirst(2)
    } else {
      rest = rest.drop(while: \.isWhitespace)
    }
    for match in rest.matches(of: child()) {
      result += escaped(rest[rest.startIndex..<match.range.lowerBound])
      result += "**" + escaped(match.1) + "**"
      rest = rest[match.range.upperBound...]
    }
    return result + escaped(rest)
  }

  /// Text that Markdown shows as it is: each ASCII punctuation mark escaped.
  private static func escaped(_ text: Substring) -> String {
    var result = ""
    for character in text {
      if character.isASCII, character.isPunctuation || character.isSymbol {
        result.append("\\")
      }
      result.append(character)
    }
    return result
  }
}
