import Foundation

/// A command line cut the way a shell would cut it, without evaluating anything (#36).
///
/// Quotes and backslashes are honoured, `&&`, `||`, `;`, `|`, `&`, a new line and parentheses end
/// a simple command, redirections and comments are dropped. A word holding a variable or a command
/// substitution is unknown — `nil` — because what it becomes is only known once the shell has run:
/// the journal never guesses a branch or a number.
public enum ShellWords {
  public static func commands(in line: String) -> [[String?]] {
    var parser = Parser(Array(line))
    parser.run()
    return parser.commands
  }

  private struct Parser {
    let characters: [Character]
    var index = 0
    var commands: [[String?]] = []
    var words: [String?] = []
    var word = ""
    var inWord = false
    var isUnknown = false
    /// The next word is where a redirection goes, not an argument.
    var skipsNextWord = false

    init(_ characters: [Character]) {
      self.characters = characters
    }

    var current: Character? { index < characters.count ? characters[index] : nil }
    var next: Character? { index + 1 < characters.count ? characters[index + 1] : nil }

    mutating func run() {
      while let character = current {
        switch character {
        case "'":
          inWord = true
          index += 1
          while let quoted = current, quoted != "'" {
            word.append(quoted)
            index += 1
          }
          index += 1
        case "\"":
          inWord = true
          index += 1
          readDoubleQuoted()
        case "\\":
          inWord = true
          if let escaped = next, escaped != "\n" { word.append(escaped) }
          index += 2
        case "$", "`":
          inWord = true
          isUnknown = true
          readExpansion()
        case " ", "\t":
          finishWord()
          index += 1
        case "\n", ";", "(", ")":
          finishCommand()
          index += 1
        case "&", "|":
          finishCommand()
          index += next == character ? 2 : 1
        case "#" where !inWord:
          while let skipped = current, skipped != "\n" { index += 1 }
        case "<", ">":
          // `2>` is a redirection of the second descriptor, not an argument `2`.
          if inWord, !isUnknown, !word.isEmpty, word.allSatisfy(\.isNumber) {
            word = ""
            inWord = false
          }
          finishWord()
          while let operatorCharacter = current, "<>&".contains(operatorCharacter) { index += 1 }
          // `2>&1` names a descriptor, which is not a word to skip.
          if let target = current, target.isNumber, characters[index - 1] == "&" {
            while let digit = current, digit.isNumber { index += 1 }
          } else {
            skipsNextWord = true
          }
        default:
          inWord = true
          word.append(character)
          index += 1
        }
      }
      finishCommand()
    }

    mutating func readDoubleQuoted() {
      while let quoted = current, quoted != "\"" {
        if quoted == "\\", let escaped = next, "$`\"\\\n".contains(escaped) {
          if escaped != "\n" { word.append(escaped) }
          index += 2
          continue
        }
        if quoted == "$" || quoted == "`" { isUnknown = true }
        word.append(quoted)
        index += 1
      }
      index += 1
    }

    /// `$VAR`, `${…}`, `$(…)` or `` `…` ``, taken whole so that what is inside does not end the
    /// command: `$(git branch --show-current)` is one word, not two commands.
    mutating func readExpansion() {
      let opening = characters[index]
      word.append(opening)
      index += 1
      if opening == "`" {
        while let inner = current, inner != "`" {
          word.append(inner)
          index += 1
        }
        index += 1
        return
      }
      guard let bracket = current, bracket == "(" || bracket == "{" else { return }
      let closing: Character = bracket == "(" ? ")" : "}"
      var depth = 0
      while let inner = current {
        word.append(inner)
        index += 1
        if inner == bracket {
          depth += 1
        } else if inner == closing {
          depth -= 1
          if depth == 0 { return }
        }
      }
    }

    mutating func finishWord() {
      guard inWord else { return }
      if skipsNextWord {
        skipsNextWord = false
      } else {
        words.append(isUnknown ? nil : word)
      }
      word = ""
      inWord = false
      isUnknown = false
    }

    mutating func finishCommand() {
      finishWord()
      skipsNextWord = false
      if !words.isEmpty { commands.append(words) }
      words = []
    }
  }
}
