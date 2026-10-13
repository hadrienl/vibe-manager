import Foundation

/// The options of the dialog at the bottom of an agent's terminal, as they read on screen (#273).
///
/// Never what a request asks — that comes from the agent's hooks — only how its dialog is drawn
/// right now: which digit, or which key, takes which option. The CLIs change their options with
/// the user's settings and modes, and a digit typed blind can take one that was never meant.
public struct AgentDialogScreen: Hashable, Sendable {
  public struct Option: Hashable, Sendable {
    /// The number drawn before it: `1.`.
    public let number: Int
    /// Its words, wrapped lines joined — without the description Codex draws in a column beside.
    public let label: String
    /// The key drawn after it, as Codex does: `(y)`, `(esc)`.
    public let shortcut: String?

    public init(number: Int, label: String, shortcut: String? = nil) {
      self.number = number
      self.label = label
      self.shortcut = shortcut
    }
  }

  /// A form of an MCP server with nothing to fill in, as Claude Code draws it: the server's words,
  /// then `❯ Accept    Decline`, no option numbered.
  public struct Confirmation: Hashable, Sendable {
    public let server: String
    /// The server's words, one line of the screen per line: wrapped to the terminal's width.
    public let message: String
    /// Whether `Accept` is pointed at: Return takes the option pointed at.
    public let isAcceptPointed: Bool

    public init(server: String, message: String, isAcceptPointed: Bool) {
      self.server = server
      self.message = message
      self.isAcceptPointed = isAcceptPointed
    }

    /// Whether this is the dialog of `elicitation`: its server, and its words, however the
    /// terminal wrapped them — nothing more between them and the choices, no field to fill in.
    public func asks(_ elicitation: AgentElicitation) -> Bool {
      guard elicitation.isConfirmation, let server = elicitation.server,
        let words = elicitation.message
      else { return false }
      let unwrapped = { (text: String) in text.filter { !$0.isWhitespace } }
      return server == self.server && !unwrapped(words).isEmpty
        && unwrapped(words) == unwrapped(message)
    }
  }

  public let options: [Option]
  /// The confirmation the screen ends on, when it ends on one rather than on numbered options.
  public let confirmation: Confirmation?

  public init(options: [Option], confirmation: Confirmation? = nil) {
    self.options = options
    self.confirmation = confirmation
  }

  /// How far from the bottom of what is drawn the dialog must end: Codex draws a form's footer
  /// under a few empty lines.
  static let bottomDistance = 14

  /// The dialog drawn last, or `nil` when the screen ends on none: its options numbered from 1,
  /// one of them pointed at — `❯` for Claude Code, `›` for Codex. An agent's own numbered list
  /// has no pointer, and is not near the bottom once the prompt is back.
  public init?(screen text: String) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard
      let lastContent = lines.lastIndex(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      })
    else { return nil }
    typealias Parsed = (line: Int, number: Int, indent: Int, isPointed: Bool, text: String)
    var parsed: [Parsed] = []
    for (index, line) in lines.enumerated() {
      if let option = Self.optionLine(line) {
        parsed.append((index, option.number, option.indent, option.isPointed, option.text))
      }
    }
    // A label wrapped onto the lines under it, indented further, until an option or a blank.
    func continuation(of option: Parsed) -> [String] {
      var words: [String] = []
      for line in lines[(option.line + 1)...] {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.trimmingCharacters(in: .whitespaces)
        guard indent > option.indent, !rest.isEmpty, Self.optionLine(line) == nil else { break }
        words.append(rest)
      }
      return words
    }
    // A rule drawn between two options: Claude Code sets "Chat about this" apart from a
    // question's options (2.1.288).
    let isRule = PromptInputRecognition.isRule
    // The last run of options numbered 1, 2, 3… one right under the other's words, or a rule.
    var run: [Parsed] = []
    for option in parsed {
      if option.number == 1 {
        run = [option]
      } else if let last = run.last, option.number == last.number + 1,
        case let next = last.line + 1 + continuation(of: last).count,
        option.line == next || (option.line == next + 1 && isRule(lines[next]))
      {
        run.append(option)
      } else {
        run = []
      }
    }
    guard let last = run.last, lastContent - last.line <= Self.bottomDistance,
      run.filter(\.isPointed).count == 1
    else {
      guard let confirmation = Self.confirmation(in: lines, lastContent: lastContent) else {
        return nil
      }
      self.options = []
      self.confirmation = confirmation
      return
    }
    var options: [Option] = []
    for option in run {
      let words = ([option.text] + continuation(of: option)).joined(separator: " ")
      let (label, shortcut) = Self.splitShortcut(words)
      options.append(Option(number: option.number, label: label, shortcut: shortcut))
    }
    self.options = options
    self.confirmation = nil
  }

  /// `MCP server “github” requests your input`, its words under it, then its two choices, one
  /// pointed at — near the bottom, as Claude Code draws them.
  static func confirmation(in lines: [String], lastContent: Int) -> Confirmation? {
    let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    func isChoices(_ line: String) -> Bool {
      line.filter { $0 == "❯" }.count == 1
        && line.split(whereSeparator: { $0 == " " || $0 == "❯" }) == ["Accept", "Decline"]
    }
    guard let choices = trimmed.lastIndex(where: isChoices),
      lastContent - choices <= bottomDistance,
      let title = trimmed[..<choices].lastIndex(where: {
        $0.wholeMatch(of: #/MCP server [“"].+[”"] requests your input/#) != nil
      }),
      let server = trimmed[title].firstMatch(of: #/[“"](.+)[”"]/#)?.1
    else { return nil }
    let message = trimmed[(title + 1)..<choices].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Confirmation(
      server: String(server), message: message, isAcceptPointed: trimmed[choices].hasPrefix("❯"))
  }

  /// `❯ 1. Yes`, `  2. No`, `› 1. Yes, proceed (y)`.
  static func optionLine(_ line: String) -> (
    number: Int, indent: Int, isPointed: Bool, text: String
  )? {
    var rest = Substring(line)
    let indent = rest.prefix { $0 == " " }.count
    rest = rest.drop { $0 == " " }
    var isPointed = false
    if let first = rest.first, "❯›".contains(first) {
      isPointed = true
      rest = rest.dropFirst().drop { $0 == " " }
    }
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
    rest = rest.dropFirst(digits.count)
    guard rest.hasPrefix(". ") else { return nil }
    var text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    // Codex's forms draw a description in a column of its own, two spaces away at least.
    if let gap = text.range(of: "  ") { text = String(text[..<gap.lowerBound]) }
    return text.isEmpty ? nil : (number, indent, isPointed, text)
  }

  /// The key in parentheses at the end of a label, when it is a key: `(y)`, `(esc)`.
  static func splitShortcut(_ words: String) -> (String, String?) {
    guard words.hasSuffix(")"), let open = words.lastIndex(of: "(") else { return (words, nil) }
    let key = words[words.index(after: open)..<words.index(before: words.endIndex)]
    guard !key.isEmpty, key.count <= 5, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" })
    else { return (words, nil) }
    return (words[..<open].trimmingCharacters(in: .whitespaces), key.lowercased())
  }

  /// The first option whose words satisfy `matches`.
  public func option(where matches: (String) -> Bool) -> Option? {
    options.first { matches($0.label) }
  }
}
