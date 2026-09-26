import Foundation

/// How a test run ended, read from what its runner printed last.
public struct TestOutcome: Hashable, Sendable {
  public let total: Int
  public let failed: Int

  public init(total: Int, failed: Int) {
    self.total = total
    self.failed = failed
  }

  public var passed: Int { max(0, total - failed) }
}

/// Recognises the summary line of the test runners agents run most, and nothing else.
///
/// A closed list on purpose: a title that says "42 tests passed" must never be a guess. Only the
/// end of the output is read, where every one of these runners writes its summary.
public enum TestOutcomeRecognizer {
  public static func outcome(in output: String) -> TestOutcome? {
    let tail = String(output.suffix(8_192))
    return outcomeOfTail(tail)
  }

  /// The outcome of a command that ran tests: `cat` of a CI log holds a summary too, and saying
  /// its `cat` failed three tests would be false.
  public static func outcome(of command: String, output: String) -> TestOutcome? {
    guard runsTests(command) else { return nil }
    return outcome(in: output)
  }

  /// Whether a command runs a test suite, from the words that do.
  public static func runsTests(_ command: String) -> Bool {
    let pattern =
      #"(^|[\s;&|(/])(swift\s+test|xcodebuild\b[^\n]*\btest|pytest|py\.test|jest|vitest|cargo\s+(nextest|test)|go\s+test|npm\s+(run\s+)?test|pnpm\s+(run\s+)?test|yarn\s+(run\s+)?test|bun\s+test|make\s+test|gradle\w*\s+test|mvn\s+test|rspec|phpunit)\b"#
    return command.range(of: pattern, options: .regularExpression) != nil
  }

  private static func outcomeOfTail(_ tail: String) -> TestOutcome? {
    for recognize in [swiftTesting, xcTest, cargo, jest, vitest, pytest, goTest] {
      if let outcome = recognize(tail) { return outcome }
    }
    return nil
  }

  /// `✘ Test run with 9 tests in 2 suites failed after 0.004 seconds with 1 issue.`
  /// `✔ Test run with 42 tests passed after 1.2 seconds.`
  static func swiftTesting(_ text: String) -> TestOutcome? {
    guard
      let match = lastMatch(
        #"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)(?:[^\n]*? with (\d+) issues?)?"#,
        in: text),
      let total = Int(match[1])
    else { return nil }
    let failed = match[2] == "failed" ? max(1, Int(match[3]) ?? 1) : 0
    return TestOutcome(total: total, failed: min(failed, total))
  }

  /// `Executed 42 tests, with 3 failures (0 unexpected) in 1.234 (1.240) seconds`
  static func xcTest(_ text: String) -> TestOutcome? {
    guard let match = lastMatch(#"Executed (\d+) tests?, with (\d+) failures?"#, in: text),
      let total = Int(match[1]), let failed = Int(match[2])
    else { return nil }
    return TestOutcome(total: total, failed: failed)
  }

  /// `test result: FAILED. 39 passed; 3 failed; 0 ignored` — once per test binary, added up.
  static func cargo(_ text: String) -> TestOutcome? {
    let matches = allMatches(#"test result: \w+\. (\d+) passed; (\d+) failed"#, in: text)
    guard !matches.isEmpty else { return nil }
    var passed = 0
    var failed = 0
    for match in matches {
      passed += Int(match[1]) ?? 0
      failed += Int(match[2]) ?? 0
    }
    return TestOutcome(total: passed + failed, failed: failed)
  }

  /// `Tests:       3 failed, 39 passed, 42 total`
  static func jest(_ text: String) -> TestOutcome? {
    guard
      let match = lastMatch(#"Tests:\s+(?:(\d+) failed, )?(?:\d+ \w+, )*(\d+) total"#, in: text),
      let total = Int(match[2])
    else { return nil }
    return TestOutcome(total: total, failed: Int(match[1]) ?? 0)
  }

  /// `Tests  3 failed | 39 passed (42)`
  static func vitest(_ text: String) -> TestOutcome? {
    guard let match = lastMatch(#"Tests\s+(?:(\d+) failed \| )?[^\n]*?\((\d+)\)"#, in: text),
      let total = Int(match[2])
    else { return nil }
    return TestOutcome(total: total, failed: Int(match[1]) ?? 0)
  }

  /// `===== 3 failed, 39 passed in 1.23s =====`
  static func pytest(_ text: String) -> TestOutcome? {
    guard let line = lastMatch(#"=+ ([^=\n]*(?:passed|failed)[^=\n]*) in [\d.]+s"#, in: text)
    else { return nil }
    let summary = line[1]
    let failed =
      Int(lastMatch(#"(\d+) failed"#, in: summary)?[1] ?? "0") ?? 0
      + (Int(lastMatch(#"(\d+) errors?"#, in: summary)?[1] ?? "0") ?? 0)
    let passed = Int(lastMatch(#"(\d+) passed"#, in: summary)?[1] ?? "0") ?? 0
    guard passed + failed > 0 else { return nil }
    return TestOutcome(total: passed + failed, failed: failed)
  }

  /// `go test -v`: one `--- PASS:` or `--- FAIL:` line per test.
  static func goTest(_ text: String) -> TestOutcome? {
    let passed = allMatches(#"(?m)^\s*--- PASS: "#, in: text).count
    let failed = allMatches(#"(?m)^\s*--- FAIL: "#, in: text).count
    guard passed + failed > 0 else { return nil }
    return TestOutcome(total: passed + failed, failed: failed)
  }

  private static func lastMatch(_ pattern: String, in text: String) -> [String]? {
    allMatches(pattern, in: text).last
  }

  private static func allMatches(_ pattern: String, in text: String) -> [[String]] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).map { match in
      (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
    }
  }
}
