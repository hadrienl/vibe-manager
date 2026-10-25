import Foundation

/// What is wrong with a text of rules, where. The message is English, precise enough to be sent
/// back to the agent as it is; the user never sees it.
public struct ArchiveRuleProblem: Error, Hashable, Sendable, CustomStringConvertible {
  public let line: Int
  public let column: Int
  public let message: String

  public init(line: Int, column: Int, message: String) {
    self.line = line
    self.column = column
    self.message = message
  }

  public var description: String {
    "line \(line), column \(column): \(message)"
  }
}

/// Reads a text of rules into a document, and checks it: every field with a comparison it takes
/// and a value of its kind, every schedule possible, every name distinct.
public enum ArchiveRuleParser {
  /// Beyond these, a text is not a set of rules a person would describe in a sentence.
  public static let maximumRules = 20
  public static let maximumProtections = 20
  public static let maximumNameLength = 60
  public static let maximumLimit = 1000
  /// The shortest interval of `every`: as often as `continuously` looks at durations.
  public static let shortestInterval = ArchiveDuration(15, .minutes)
  public static let maximumTextLength = 20_000

  /// Whether a name holds no invisible character that reorders or hides text. The joiner of
  /// emoji such as 🧑‍💻 hides nothing, and is kept.
  public static func isReadableName(_ name: String) -> Bool {
    !name.unicodeScalars.contains {
      $0.properties.isBidiControl
        || ($0.properties.generalCategory == .format && $0.value != 0x200D)
    }
  }

  public static func parse(_ text: String) throws(ArchiveRuleProblem) -> ArchiveRuleDocument {
    guard text.utf8.count <= maximumTextLength else {
      throw ArchiveRuleProblem(
        line: 1, column: 1, message: "The text is longer than \(maximumTextLength) bytes.")
    }
    var lexer = Lexer(text)
    var parser = Parser(tokens: try lexer.tokens())
    return try parser.document()
  }
}

// MARK: - Tokens

private struct Token: Equatable {
  enum Kind: Equatable {
    case word(String)
    case string(String)
    case color(String)
    case integer(Int)
    case duration(ArchiveDuration)
    case date(ArchiveDay)
    case time(ArchiveTime)
    case symbol(String)
    case end
  }

  let kind: Kind
  let line: Int
  let column: Int

  var spelling: String {
    switch kind {
    case .word(let word): "`\(word)`"
    case .string(let text): "the text \"\(text)\""
    case .color(let hex): "`\(hex)`"
    case .integer(let number): "`\(number)`"
    case .duration(let duration): "`\(duration.count)\(duration.unit.rawValue)`"
    case .date(let day): "`\(day.text)`"
    case .time(let time): "`\(time.text)`"
    case .symbol(let symbol): "`\(symbol)`"
    case .end: "the end of the text"
    }
  }
}

private struct Lexer {
  private let characters: [Character]
  private var index = 0
  private var line = 1
  private var column = 1

  init(_ text: String) {
    characters = Array(text)
  }

  mutating func tokens() throws(ArchiveRuleProblem) -> [Token] {
    var result: [Token] = []
    while true {
      skipBlanks()
      let token = try next()
      result.append(token)
      if token.kind == .end { return result }
    }
  }

  private var current: Character? {
    index < characters.count ? characters[index] : nil
  }

  private func peek(_ offset: Int) -> Character? {
    index + offset < characters.count ? characters[index + offset] : nil
  }

  private mutating func advance() {
    guard let character = current else { return }
    index += 1
    if character == "\n" {
      line += 1
      column = 1
    } else {
      column += 1
    }
  }

  private mutating func skipBlanks() {
    while let character = current {
      if character.isWhitespace {
        advance()
      } else if character == "/", peek(1) == "/" {
        while let next = current, next != "\n" { advance() }
      } else {
        return
      }
    }
  }

  private func problem(_ message: String, line: Int? = nil, column: Int? = nil)
    -> ArchiveRuleProblem
  {
    ArchiveRuleProblem(line: line ?? self.line, column: column ?? self.column, message: message)
  }

  private mutating func next() throws(ArchiveRuleProblem) -> Token {
    let line = line
    let column = column
    func token(_ kind: Token.Kind) -> Token {
      Token(kind: kind, line: line, column: column)
    }
    guard let character = current else { return token(.end) }

    if character == "\"" {
      return token(.string(try string()))
    }
    if character == "#" {
      advance()
      var hex = ""
      while let next = current, next.isASCII, next.isLetter || next.isNumber {
        hex.append(next)
        advance()
      }
      guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
        throw problem(
          "A colour is written `#RRGGBB`, six hexadecimal digits; `#\(hex)` is not one.",
          line: line, column: column)
      }
      return token(.color("#" + hex.uppercased()))
    }
    if character.isASCII, character.isNumber {
      return token(try number(line: line, column: column))
    }
    if character.isASCII, character.isLetter {
      var word = ""
      while let next = current,
        next.isASCII
          && (next.isLetter || next.isNumber || next == "." || next == "-" || next == "_")
      {
        word.append(next)
        advance()
      }
      return token(.word(word))
    }
    for symbol in ["!=", ">=", "<="] where character == symbol.first && peek(1) == symbol.last {
      advance()
      advance()
      return token(.symbol(symbol))
    }
    if "()[],=~".contains(character) {
      advance()
      return token(.symbol(String(character)))
    }
    throw problem("Unexpected character `\(character)`.")
  }

  private mutating func string() throws(ArchiveRuleProblem) -> String {
    let line = line
    let column = column
    advance()
    var text = ""
    while true {
      guard let character = current, character != "\n" else {
        throw problem("A text opened here is never closed by `\"`.", line: line, column: column)
      }
      advance()
      if character == "\"" { return text }
      if character == "\\" {
        guard let escaped = current, escaped == "\"" || escaped == "\\" else {
          throw problem("Only `\\\"` and `\\\\` may follow a backslash in a text.")
        }
        text.append(escaped)
        advance()
        continue
      }
      guard !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      else {
        throw problem("A text cannot hold a control character.")
      }
      text.append(character)
    }
  }

  private mutating func digits() -> String {
    var text = ""
    while let next = current, next.isASCII, next.isNumber {
      text.append(next)
      advance()
    }
    return text
  }

  private mutating func number(line: Int, column: Int) throws(ArchiveRuleProblem) -> Token.Kind {
    let first = digits()
    if current == "-", first.count == 4 {
      advance()
      let month = digits()
      guard current == "-" else {
        throw problem("A day is written `YYYY-MM-DD`.", line: line, column: column)
      }
      advance()
      let day = digits()
      guard month.count == 2, day.count == 2, let year = Int(first), let monthNumber = Int(month),
        let dayNumber = Int(day), (1...12).contains(monthNumber), (1...31).contains(dayNumber)
      else {
        throw problem(
          "A day is written `YYYY-MM-DD`, with a real month and day.", line: line, column: column)
      }
      let date = ArchiveDay(year: year, month: monthNumber, day: dayNumber)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
      guard let start = date.start(in: calendar),
        calendar.component(.day, from: start) == dayNumber
      else {
        throw problem("`\(date.text)` is not a day of the calendar.", line: line, column: column)
      }
      return .date(date)
    }
    if current == ":" {
      advance()
      let minutes = digits()
      guard first.count == 2, minutes.count == 2, let hour = Int(first), let minute = Int(minutes),
        hour < 24, minute < 60
      else {
        throw problem(
          "A time is written `HH:MM`, from `00:00` to `23:59`.", line: line, column: column)
      }
      return .time(ArchiveTime(hour: hour, minute: minute))
    }
    guard let count = Int(first), first.count <= 6 else {
      throw problem("`\(first)` is too large a number.", line: line, column: column)
    }
    if let unitCharacter = current,
      let unit = ArchiveDuration.Unit(rawValue: String(unitCharacter)),
      !(peek(1).map { $0.isLetter || $0.isNumber } ?? false)
    {
      advance()
      return .duration(ArchiveDuration(count, unit))
    }
    if let next = current, next.isLetter {
      throw problem(
        "A duration is a number followed by `m`, `h`, `d` or `w`, such as `3d`.", line: line,
        column: column)
    }
    return .integer(count)
  }
}

// MARK: - Grammar

private struct Parser {
  let tokens: [Token]
  var position = 0

  init(tokens: [Token]) {
    self.tokens = tokens
  }

  var current: Token { tokens[position] }

  mutating func advance() {
    if position < tokens.count - 1 { position += 1 }
  }

  func problem(_ message: String, at token: Token? = nil) -> ArchiveRuleProblem {
    let token = token ?? current
    return ArchiveRuleProblem(line: token.line, column: token.column, message: message)
  }

  func isWord(_ word: String) -> Bool {
    current.kind == .word(word)
  }

  func isSymbol(_ symbol: String) -> Bool {
    current.kind == .symbol(symbol)
  }

  mutating func expectWord(_ word: String, _ context: String) throws(ArchiveRuleProblem) {
    guard isWord(word) else {
      throw problem("Expected `\(word)` \(context), found \(current.spelling).")
    }
    advance()
  }

  mutating func document() throws(ArchiveRuleProblem) -> ArchiveRuleDocument {
    var document = ArchiveRuleDocument()
    var names: [String: Token] = [:]
    while current.kind != .end {
      if isWord("rule") {
        let start = current
        let rule = try rule()
        let key = rule.name.lowercased()
        if names[key] != nil {
          throw problem(
            "Two rules are named \"\(rule.name)\"; each rule needs its own name.", at: start)
        }
        names[key] = start
        document.rules.append(rule)
        guard document.rules.count <= ArchiveRuleParser.maximumRules else {
          throw problem("At most \(ArchiveRuleParser.maximumRules) rules.", at: start)
        }
      } else if isWord("protect") {
        let start = current
        advance()
        try expectWord("where", "after `protect`")
        document.protections.append(ArchiveProtection(condition: try expression()))
        guard document.protections.count <= ArchiveRuleParser.maximumProtections else {
          throw problem("At most \(ArchiveRuleParser.maximumProtections) protections.", at: start)
        }
      } else {
        throw problem("Expected `rule` or `protect`, found \(current.spelling).")
      }
    }
    guard !document.isEmpty else {
      throw problem("The text holds no rule and no protection.")
    }
    return document
  }

  mutating func rule() throws(ArchiveRuleProblem) -> ArchiveRule {
    advance()
    guard case .string(let name) = current.kind else {
      throw problem("Expected the rule's name in quotes after `rule`, found \(current.spelling).")
    }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed == name else {
      throw problem("A rule's name is not empty, and neither starts nor ends with a space.")
    }
    guard name.count <= ArchiveRuleParser.maximumNameLength else {
      throw problem("A rule's name is at most \(ArchiveRuleParser.maximumNameLength) characters.")
    }
    guard ArchiveRuleParser.isReadableName(name) else {
      throw problem("A rule's name cannot hold characters that reorder text.")
    }
    advance()
    try expectWord("archive", "after the rule's name")
    try expectWord("done", "after `archive`: only done sessions are archived")
    try expectWord("sessions", "after `archive done`")
    var condition: ArchiveCondition?
    if isWord("where") {
      advance()
      condition = try expression()
    }
    try expectWord("on", "before the rule's schedule")
    let scheduleToken = current
    let schedule = try schedule()
    var rule = ArchiveRule(name: name, condition: condition, schedule: schedule)
    var seenLimit = false
    var seenCatchUp = false
    while true {
      if isWord("limit") {
        guard !seenLimit else { throw problem("`limit` is given twice.") }
        seenLimit = true
        advance()
        guard case .integer(let count) = current.kind,
          (1...ArchiveRuleParser.maximumLimit).contains(count)
        else {
          throw problem(
            "`limit` takes a number from 1 to \(ArchiveRuleParser.maximumLimit), found "
              + "\(current.spelling).")
        }
        rule.limit = count
        advance()
      } else if isWord("no") {
        guard !seenCatchUp else { throw problem("`no catch-up` is given twice.") }
        seenCatchUp = true
        advance()
        try expectWord("catch-up", "after `no`")
        guard schedule != .continuously else {
          throw problem(
            "`no catch-up` means nothing for a rule that runs `continuously`.", at: scheduleToken)
        }
        rule.catchesUp = false
      } else {
        return rule
      }
    }
  }

  mutating func time() throws(ArchiveRuleProblem) -> ArchiveTime {
    try expectWord("at", "before the time")
    guard case .time(let time) = current.kind else {
      throw problem("Expected a time `HH:MM` after `at`, found \(current.spelling).")
    }
    advance()
    return time
  }

  mutating func weekday() throws(ArchiveRuleProblem) -> ArchiveWeekday {
    guard case .word(let word) = current.kind,
      let day = ArchiveWeekday.allCases.first(where: { $0.keyword == word })
    else {
      throw problem("Expected a day of the week (`monday` … `sunday`), found \(current.spelling).")
    }
    advance()
    return day
  }

  mutating func schedule() throws(ArchiveRuleProblem) -> ArchiveSchedule {
    let start = current
    guard case .word(let word) = current.kind else {
      throw problem(
        "Expected `daily`, `weekdays`, `weekly`, `monthly`, `every` or `continuously`, found "
          + "\(current.spelling).")
    }
    advance()
    switch word {
    case "daily":
      return .daily(try time())
    case "weekdays":
      return .weekdays(try time())
    case "weekly":
      var days = [try weekday()]
      while isSymbol(",") {
        advance()
        let day = try weekday()
        guard !days.contains(day) else { throw problem("`\(day.keyword)` is given twice.") }
        days.append(day)
      }
      return .weekly(days, try time())
    case "monthly":
      var days = [try monthDay()]
      while isSymbol(",") {
        advance()
        let token = current
        let day = try monthDay()
        guard !days.contains(day) else {
          throw problem("A day of the month is given twice.", at: token)
        }
        days.append(day)
      }
      return .monthly(days, try time())
    case "every":
      guard case .duration(let interval) = current.kind else {
        throw problem(
          "Expected an interval such as `3d` or `6h` after `every`, found \(current.spelling).")
      }
      guard interval >= ArchiveRuleParser.shortestInterval else {
        throw problem("The interval of `every` is at least 15m.")
      }
      guard interval <= ArchiveDuration(52, .weeks) else {
        throw problem("The interval of `every` is at most 52w.")
      }
      advance()
      guard isWord("at") else { return .every(interval, nil) }
      guard interval.unit == .days || interval.unit == .weeks else {
        throw problem("`every` with a time takes an interval in days or weeks.", at: start)
      }
      return .every(interval, try time())
    case "continuously":
      return .continuously
    default:
      throw problem(
        "Expected `daily`, `weekdays`, `weekly`, `monthly`, `every` or `continuously`, found "
          + "`\(word)`.", at: start)
    }
  }

  mutating func monthDay() throws(ArchiveRuleProblem) -> ArchiveMonthDay {
    switch current.kind {
    case .integer(let day):
      guard (1...31).contains(day) else {
        throw problem("A day of the month is from 1 to 31; `\(day)` is not.")
      }
      advance()
      return .number(day)
    case .word("last") where tokens[position + 1].kind == .word("day"):
      advance()
      advance()
      return .lastDay
    case .word(let word):
      guard let ordinal = ArchiveOrdinal(rawValue: word) else { break }
      advance()
      return .weekday(ordinal, try weekday())
    default:
      break
    }
    throw problem(
      "Expected a day of the month: a number, `last day`, or `first`…`fourth`/`last` and a day of "
        + "the week; found \(current.spelling).")
  }

  // MARK: Conditions

  mutating func expression() throws(ArchiveRuleProblem) -> ArchiveCondition {
    var terms = [try term()]
    while isWord("or") {
      advance()
      terms.append(try term())
    }
    return terms.count == 1 ? terms[0] : .any(terms)
  }

  mutating func term() throws(ArchiveRuleProblem) -> ArchiveCondition {
    var factors = [try factor()]
    while isWord("and") {
      advance()
      factors.append(try factor())
    }
    return factors.count == 1 ? factors[0] : .all(factors)
  }

  mutating func factor() throws(ArchiveRuleProblem) -> ArchiveCondition {
    if isWord("not") {
      advance()
      return .not(try factor())
    }
    if isSymbol("(") {
      advance()
      let inner = try expression()
      guard isSymbol(")") else { throw problem("Expected `)`, found \(current.spelling).") }
      advance()
      return inner
    }
    return .test(try test())
  }

  mutating func test() throws(ArchiveRuleProblem) -> ArchiveTest {
    guard case .word(let word) = current.kind, let field = ArchiveField(rawValue: word) else {
      throw problem(
        "Expected a field (\(ArchiveField.allCases.map { "`\($0.keyword)`" }.joined(separator: ", "))), "
          + "found \(current.spelling).")
    }
    advance()
    if field.valueKind == .fact {
      if field == .gitDirty { return ArchiveTest(field, .isTrue, .none) }
      guard case .word(let word) = current.kind,
        let comparison = [ArchiveComparison.isTrue, .isFalse].first(where: { $0.rawValue == word })
      else {
        throw problem("`\(field.keyword)` is followed by `present` or `absent`.")
      }
      advance()
      return ArchiveTest(field, comparison, .none)
    }

    let comparisonToken = current
    let comparison: ArchiveComparison?
    switch current.kind {
    case .symbol(let symbol), .word(let symbol):
      comparison = ArchiveComparison(rawValue: symbol)
    default:
      comparison = nil
    }
    guard let comparison, field.comparisons.contains(comparison) else {
      throw problem(
        "`\(field.keyword)` takes "
          + field.comparisons.map { "`\($0.rawValue)`" }.joined(separator: ", ")
          + "; found \(current.spelling).", at: comparisonToken)
    }
    advance()

    let valueToken = current
    let value: ArchiveValue
    if comparison == .in {
      guard isSymbol("[") else {
        throw problem("`in` takes a list in brackets, such as `[#B42318, #A65B00]`.")
      }
      advance()
      var items = [try scalar(for: field, comparison: comparison)]
      while isSymbol(",") {
        advance()
        items.append(try scalar(for: field, comparison: comparison))
      }
      guard isSymbol("]") else { throw problem("Expected `]` or `,`, found \(current.spelling).") }
      advance()
      guard Set(items).count == items.count else {
        throw problem("A value is given twice in the list.", at: valueToken)
      }
      value = .list(items)
    } else {
      value = try scalar(for: field, comparison: comparison)
    }
    return ArchiveTest(field, comparison, value)
  }

  mutating func scalar(for field: ArchiveField, comparison: ArchiveComparison)
    throws(ArchiveRuleProblem) -> ArchiveValue
  {
    let token = current
    let value: ArchiveValue
    switch (field.valueKind, token.kind) {
    case (.color, .color(let hex)):
      value = .color(hex)
    case (.text, .string(let text)):
      guard !text.isEmpty else {
        throw problem("`\(field.keyword)` is compared with an empty text.")
      }
      if comparison == .matches, text.contains(where: { "[]{}^$|\\+".contains($0) }) {
        throw problem(
          "A pattern after `~` only knows `*` (any characters) and `?` (one character); it is not "
            + "a regular expression.")
      }
      value = .text(text)
    case (.words(let words), .word(let word)):
      guard words.isEmpty || words.contains(word) else {
        throw problem(
          "`\(field.keyword)` is one of "
            + words.map { "`\($0)`" }.joined(separator: ", ") + "; found `\(word)`.")
      }
      value = .word(word)
    case (.integer, .integer(let number)):
      value = .integer(number)
    case (.duration, .duration(let duration)):
      value = .duration(duration)
    case (.date, .date(let day)):
      value = .date(day)
    default:
      throw problem(
        "`\(field.keyword)` is compared with \(Self.expected(field.valueKind)); found \(token.spelling)."
      )
    }
    advance()
    return value
  }

  static func expected(_ kind: ArchiveValueKind) -> String {
    switch kind {
    case .color: "a colour `#RRGGBB`"
    case .text: "a text in quotes"
    case .words(let words):
      words.isEmpty ? "an identifier" : "one of " + words.map { "`\($0)`" }.joined(separator: ", ")
    case .integer: "a whole number"
    case .duration: "a duration such as `3d`, `48h`, `30m` or `2w`"
    case .date: "a day `YYYY-MM-DD`"
    case .fact: "nothing"
    }
  }
}
