import Foundation
import Testing

@testable import VibePersistence

private func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions =
    fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
  return formatter
}

@Test("The dates the store writes are read without a formatter, to the same bit")
func storeDatesMatchTheFormatterBitForBit() throws {
  let formatter = makeFormatter(fractional: true)
  var generator = SystemRandomNumberGenerator()
  // 1970 to 9999, to the millisecond: every date the fast path accepts.
  let range: ClosedRange<Int64> = 0...253_402_300_799_999

  for _ in 0..<10_000 {
    let milliseconds = Int64.random(in: range, using: &generator)
    let text = formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    let expected = try #require(formatter.date(from: text))

    let fast = try #require(StoreDates.utcMilliseconds(text), "\(text)")

    #expect(
      fast.timeIntervalSinceReferenceDate.bitPattern
        == expected.timeIntervalSinceReferenceDate.bitPattern, "\(text)")
  }
}

@Test("Every date the store writes takes the fast path")
func writtenDatesTakeTheFastPath() {
  let dates = [
    Date(timeIntervalSince1970: 0),
    Date(timeIntervalSince1970: 1_700_000_000.25),
    Date(timeIntervalSince1970: 951_782_400),  // 2000-02-29
    Date(timeIntervalSince1970: 4_102_444_799.999),  // 2099-12-31T23:59:59.999
    Date(),
  ]

  for date in dates {
    #expect(StoreDates.utcMilliseconds(StoreDates.format(date)) != nil)
  }
}

@Test(
  "Other shapes fall back to the formatters",
  arguments: [
    "2026-09-21T10:00:13Z",
    "2026-09-21T10:00:13.9Z",
    "2026-09-21T10:00:13.123+02:00",
    "1969-07-20T20:17:40.000Z",
  ])
func otherShapesFallBack(text: String) throws {
  let expected = try #require(
    makeFormatter(fractional: true).date(from: text)
      ?? makeFormatter(fractional: false).date(from: text))

  #expect(StoreDates.utcMilliseconds(text) == nil)
  #expect(StoreDates.parse(text) == expected)
}

@Test(
  "Malformed dates are refused by the fast path",
  arguments: [
    "2026-13-21T10:00:13.000Z",
    "2026-02-30T10:00:13.000Z",
    "2025-02-29T10:00:13.000Z",
    "2026-09-21T24:00:13.000Z",
    "2026-09-21T10:60:13.000Z",
    "2026-09-21T10:00:60.000Z",
    "2026-09-21 10:00:13.000Z",
    "2026-09-21T10:00:13,000Z",
    "2026-09-2aT10:00:13.000Z",
    "2026-09-21T10:00:13.00Z",
    "2026-09-21T10:00:13.0000Z",
    "future",
  ])
func malformedDatesAreRefused(text: String) {
  #expect(StoreDates.utcMilliseconds(text) == nil)
}

@Test("A leap day is read by the fast path")
func leapDayIsRead() throws {
  let text = "2028-02-29T12:34:56.789Z"
  let expected = try #require(makeFormatter(fractional: true).date(from: text))

  #expect(StoreDates.utcMilliseconds(text) == expected)
}
