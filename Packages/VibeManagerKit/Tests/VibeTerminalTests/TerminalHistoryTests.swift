import Testing
import VibeApplication

@testable import VibeTerminal

private func bytes(_ text: String) -> [UInt8] {
  [UInt8](text.utf8)
}

@Test("History keeps everything below the limits")
func historyKeepsSmallOutput() {
  var history = TerminalHistory(limits: .default)

  history.append(bytes("first\n"))
  history.append(bytes("second\n"))

  #expect(history.snapshot.bytes == bytes("first\nsecond\n"))
  #expect(history.snapshot.droppedByteCount == 0)
}

@Test("History drops the oldest output once the byte budget is exceeded")
func historyBoundsBytes() {
  var history = TerminalHistory(
    limits: TerminalScrollbackLimits(maximumLineCount: 10_000, maximumByteCount: 64)
  )

  for index in 0..<100 {
    history.append(bytes("line-\(index)\n"))
  }

  let snapshot = history.snapshot
  #expect(snapshot.bytes.count <= 64 + 16)
  #expect(snapshot.droppedByteCount > 0)
  #expect(String(decoding: snapshot.bytes, as: UTF8.self).contains("line-99"))
  #expect(!String(decoding: snapshot.bytes, as: UTF8.self).contains("line-0\n"))
}

@Test("History drops the oldest output once the line budget is exceeded")
func historyBoundsLines() {
  var history = TerminalHistory(
    limits: TerminalScrollbackLimits(maximumLineCount: 5, maximumByteCount: 1_024 * 1_024)
  )

  for index in 0..<50 {
    history.append(bytes("line-\(index)\n"))
  }

  let text = String(decoding: history.snapshot.bytes, as: UTF8.self)
  #expect(text.components(separatedBy: "\n").count - 1 <= 6)
  #expect(text.contains("line-49"))
}

@Test("A single line larger than the budget is still shown")
func historyKeepsTheLatestBlock() {
  var history = TerminalHistory(
    limits: TerminalScrollbackLimits(maximumLineCount: 10, maximumByteCount: 16)
  )

  history.append(bytes("old\n"))
  history.append(bytes(String(repeating: "x", count: 1_000)))

  #expect(history.snapshot.bytes.count == 1_000)
  #expect(history.snapshot.droppedByteCount == 4)
}

@Test("Appending reports the bytes dropped by that append")
func historyReportsDroppedBytes() {
  var history = TerminalHistory(
    limits: TerminalScrollbackLimits(maximumLineCount: 1_000, maximumByteCount: 8)
  )

  #expect(history.append(bytes("12345678")) == 0)
  #expect(history.append(bytes("abcdefgh")) == 8)
  #expect(history.snapshot.droppedByteCount == 8)
}
