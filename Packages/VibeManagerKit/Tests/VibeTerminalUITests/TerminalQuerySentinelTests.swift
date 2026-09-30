import Testing

@testable import VibeTerminalUI

@Suite("What a suspended terminal must still answer (#248)")
struct TerminalQuerySentinelTests {
  private func scan(_ text: String) -> TerminalQuerySentinel.Query? {
    var sentinel = TerminalQuerySentinel()
    return sentinel.scan(Array(text.utf8))
  }

  @Test(
    "Every question SwiftTerm answers is recognised",
    arguments: [
      ("\u{1B}[6n", TerminalQuerySentinel.Query.statusReport),
      ("\u{1B}[?6n", .statusReport),
      ("\u{1B}[5n", .statusReport),
      ("\u{1B}[c", .attributes),
      ("\u{1B}[0c", .attributes),
      ("\u{1B}[>c", .attributes),
      ("\u{1B}[=c", .attributes),
      ("\u{1B}[?u", .keyboard),
      ("\u{1B}[?2004$p", .mode),
      ("\u{1B}[4$p", .mode),
      ("\u{1B}[>q", .version),
      ("\u{1B}[>0q", .version),
      ("\u{1B}[1;1;1;1;1*y", .checksum),
      ("\u{1B}[18t", .window),
      ("\u{1B}[14;2t", .window),
      ("\u{1B}]10;?\u{07}", .colour),
      ("\u{1B}]11;?\u{1B}\\", .colour),
      ("\u{1B}]4;1;?\u{07}", .colour),
      ("\u{1B}]52;c;?\u{07}", .clipboard),
      ("\u{1B}]7;file://host/tmp\u{07}", .directory),
      ("\u{1B}P$qm\u{1B}\\", .setting),
      ("\u{1B}P+q544e\u{1B}\\", .setting),
      ("\u{1B}_Gi=1,a=q;AAAA\u{1B}\\", .graphics),
    ])
  func recognisesQueries(_ sequence: String, _ query: TerminalQuerySentinel.Query) {
    #expect(scan("before \(sequence) after") == query)
  }

  @Test(
    "What only draws is not a question",
    arguments: [
      "plain text\r\n",
      "\u{1B}[31mred\u{1B}[0m",
      "\u{1B}[2J\u{1B}[H",
      "\u{1B}[u",
      "\u{1B}[8;24;80t",
      "\u{1B}]0;title\u{07}",
      "\u{1B}]10;#ffffff\u{07}",
      "\u{1B}(B",
      "\u{1B}[?1049h",
    ])
  func ignoresDrawing(_ text: String) {
    #expect(scan(text) == nil)
  }

  @Test("A question cut between two reads is recognised when it ends")
  func questionAcrossReads() {
    var sentinel = TerminalQuerySentinel()
    #expect(sentinel.scan(Array("out\u{1B}".utf8)) == nil)
    #expect(sentinel.scan(Array("[".utf8)) == nil)
    #expect(sentinel.scan(Array("6".utf8)) == nil)
    #expect(sentinel.scan(Array("n more".utf8)) == .statusReport)

    #expect(sentinel.scan(Array("\u{1B}]11;".utf8)) == nil)
    #expect(sentinel.scan(Array("?\u{1B}".utf8)) == nil)
    #expect(sentinel.scan(Array("\\".utf8)) == .colour)
  }

  @Test("A question written inside a title is part of the title")
  func noFalseAlarmInsideATitle() {
    #expect(scan("\u{1B}]2;see [6n and [c\u{07}") == nil)
  }

  @Test("A string interrupted by another sequence ends unanswered, and the next one counts")
  func interruptedString() {
    #expect(scan("\u{1B}]11;?\u{1B}[6n") == .statusReport)
  }
}
