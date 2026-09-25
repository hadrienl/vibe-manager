import Foundation

/// Colours code by its words, not by its grammar (#38).
///
/// Keywords, strings, comments, numbers, type names and called functions, for a dozen languages
/// agents write most. It is wrong on the corners — a keyword used as a label, a string inside an
/// interpolation — and that is the price of having no dependency and no parser: the text itself
/// is never changed, only its colours.
public enum SyntaxHighlighter {
  public enum Kind: Hashable, Sendable {
    case plain, keyword, string, comment, number, type, function, added, removed, meta
  }

  public struct Segment: Hashable, Sendable {
    public let text: String
    public let kind: Kind
  }

  struct Language {
    var keywords: Set<String>
    var lineComments: [String]
    var blockComment: (open: String, close: String)?
    var quotes: Set<Character>
    var capitalizedAreTypes = true
  }

  public static func segments(of code: String, language: String?) -> [Segment] {
    let name = (language ?? "").lowercased()
    if name == "diff" || name == "patch" { return diff(code) }
    guard let definition = definition(for: name) else { return [Segment(text: code, kind: .plain)] }
    return lex(code, definition)
  }

  static func definition(for name: String) -> Language? {
    let cStyle: [String] = ["//"]
    switch name {
    case "swift":
      return Language(
        keywords: [
          "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
          "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
          "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import",
          "in", "init", "inout", "internal", "is", "let", "mutating", "nil", "nonisolated",
          "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows",
          "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch",
          "throw", "throws", "true", "try", "typealias", "var", "where", "while",
        ], lineComments: cStyle, blockComment: ("/*", "*/"), quotes: ["\""])
    case "kotlin", "kt", "java":
      return Language(
        keywords: [
          "abstract", "as", "break", "class", "continue", "data", "do", "else", "enum", "extends",
          "false", "final", "for", "fun", "if", "implements", "import", "in", "interface", "is",
          "new", "null", "object", "override", "package", "private", "protected", "public",
          "return", "sealed", "static", "super", "suspend", "this", "throw", "true", "try",
          "val", "var", "void", "when", "while",
        ], lineComments: cStyle, blockComment: ("/*", "*/"), quotes: ["\"", "'"])
    case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs":
      return Language(
        keywords: [
          "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
          "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
          "from", "function", "if", "implements", "import", "in", "instanceof", "interface",
          "let", "new", "null", "of", "private", "public", "readonly", "return", "static",
          "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined",
          "var", "void", "while", "yield",
        ], lineComments: cStyle, blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"])
    case "python", "py":
      return Language(
        keywords: [
          "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
          "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
          "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
          "self", "True", "try", "while", "with", "yield",
        ], lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"])
    case "sh", "bash", "zsh", "shell", "console", "fish":
      return Language(
        keywords: [
          "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
          "in", "local", "return", "set", "then", "until", "while",
        ], lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], capitalizedAreTypes: false)
    case "json", "jsonc", "jsonl":
      return Language(
        keywords: ["true", "false", "null"], lineComments: name == "jsonc" ? cStyle : [],
        blockComment: nil, quotes: ["\""], capitalizedAreTypes: false)
    case "yaml", "yml", "toml":
      return Language(
        keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"],
        blockComment: nil, quotes: ["\"", "'"], capitalizedAreTypes: false)
    case "go", "golang":
      return Language(
        keywords: [
          "break", "case", "chan", "const", "continue", "default", "defer", "else", "false",
          "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package",
          "range", "return", "select", "struct", "switch", "true", "type", "var",
        ], lineComments: cStyle, blockComment: ("/*", "*/"), quotes: ["\"", "`"])
    case "rust", "rs":
      return Language(
        keywords: [
          "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
          "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
          "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
          "type", "unsafe", "use", "where", "while",
        ], lineComments: cStyle, blockComment: ("/*", "*/"), quotes: ["\""])
    case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m", "mm":
      return Language(
        keywords: [
          "auto", "bool", "break", "case", "char", "class", "const", "continue", "default",
          "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "if",
          "include", "int", "long", "namespace", "new", "nil", "NULL", "nullptr", "private",
          "public", "return", "self", "short", "signed", "sizeof", "static", "struct",
          "switch", "template", "this", "true", "typedef", "unsigned", "void", "while",
        ], lineComments: cStyle, blockComment: ("/*", "*/"), quotes: ["\"", "'"])
    case "ruby", "rb":
      return Language(
        keywords: [
          "begin", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "if",
          "module", "nil", "require", "rescue", "return", "self", "then", "true", "unless",
          "until", "when", "while", "yield",
        ], lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"])
    default:
      return nil
    }
  }

  static func lex(_ code: String, _ language: Language) -> [Segment] {
    var segments: [Segment] = []
    var plain = ""
    let characters = Array(code)
    var index = 0

    func flushPlain() {
      guard !plain.isEmpty else { return }
      segments.append(Segment(text: plain, kind: .plain))
      plain = ""
    }
    func emit(_ text: String, _ kind: Kind) {
      flushPlain()
      segments.append(Segment(text: text, kind: kind))
    }
    func starts(with prefix: String, at position: Int) -> Bool {
      let prefix = Array(prefix)
      guard position + prefix.count <= characters.count else { return false }
      return Array(characters[position..<(position + prefix.count)]) == prefix
    }

    while index < characters.count {
      let character = characters[index]
      if language.lineComments.contains(where: { starts(with: $0, at: index) }) {
        var end = index
        while end < characters.count, characters[end] != "\n" { end += 1 }
        emit(String(characters[index..<end]), .comment)
        index = end
        continue
      }
      if let block = language.blockComment, starts(with: block.open, at: index) {
        var end = index + block.open.count
        while end < characters.count, !starts(with: block.close, at: end) { end += 1 }
        end = min(characters.count, end + block.close.count)
        emit(String(characters[index..<end]), .comment)
        index = end
        continue
      }
      if language.quotes.contains(character) {
        var end = index + 1
        while end < characters.count, characters[end] != character {
          if characters[end] == "\\" {
            end += 2
            continue
          }
          if characters[end] == "\n", character != "`" { break }
          end += 1
        }
        end = min(characters.count, end + 1)
        emit(String(characters[index..<end]), .string)
        index = end
        continue
      }
      if character.isNumber, index == 0 || !isIdentifier(characters[index - 1]) {
        var end = index
        while end < characters.count,
          characters[end].isHexDigit || characters[end] == "." || characters[end] == "_"
            || characters[end] == "x"
        {
          end += 1
        }
        emit(String(characters[index..<end]), .number)
        index = end
        continue
      }
      if isIdentifierStart(character) {
        var end = index
        while end < characters.count, isIdentifier(characters[end]) { end += 1 }
        let word = String(characters[index..<end])
        let kind: Kind
        if language.keywords.contains(word) {
          kind = .keyword
        } else if end < characters.count, characters[end] == "(" {
          kind = .function
        } else if language.capitalizedAreTypes, word.first?.isUppercase == true {
          kind = .type
        } else {
          kind = .plain
        }
        if kind == .plain { plain += word } else { emit(word, kind) }
        index = end
        continue
      }
      plain.append(character)
      index += 1
    }
    flushPlain()
    return segments
  }

  static func diff(_ code: String) -> [Segment] {
    code.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
      index, line in
      let text = (index == 0 ? "" : "\n") + line
      if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
        return Segment(text: text, kind: .meta)
      }
      if line.hasPrefix("+") { return Segment(text: text, kind: .added) }
      if line.hasPrefix("-") { return Segment(text: text, kind: .removed) }
      return Segment(text: text, kind: .plain)
    }
  }

  private static func isIdentifierStart(_ character: Character) -> Bool {
    character.isLetter || character == "_" || character == "$" || character == "@"
  }

  private static func isIdentifier(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "$"
  }
}
