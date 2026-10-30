import Foundation
import SwiftUI
import Testing
import VibeApplication

@testable import VibeConversationUI

/// The day separators of the conversation, and the time under its messages (#458).
@Suite("The days of a conversation")
struct ConversationDaysTests {
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }

  private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  private static func prompt(_ id: String, _ date: Date?) -> ConversationBlock {
    .entry(ConversationEntry(id: id, date: date, content: .userPrompt(id, attachments: [])))
  }

  private static func answer(_ id: String, _ date: Date?) -> ConversationBlock {
    .entry(ConversationEntry(id: id, date: date, content: .agentText(id)))
  }

  private static func tool(_ id: String, _ date: Date?) -> ConversationBlock {
    .entry(
      ConversationEntry(
        id: id, date: date, content: .tool(ToolCall(callID: id, kind: .shell, state: .succeeded))))
  }

  private static func days(_ blocks: [ConversationBlock]) -> ConversationDays {
    var days = ConversationDays()
    days.calendar = calendar
    days.update(blocks, from: 0)
    return days
  }

  @Test("The first message of each day opens it, the first of the conversation among them")
  func groupsByDay() {
    let blocks = [
      Self.prompt("a", Self.date(28, 23, 50)),
      Self.answer("b", Self.date(28, 23, 59)),
      Self.prompt("c", Self.date(29, 0, 5)),
      Self.answer("d", Self.date(29, 9)),
      Self.prompt("e", Self.date(30, 14, 32)),
    ]
    let days = Self.days(blocks)
    #expect(days.day(opening: "a") == Self.calendar.startOfDay(for: Self.date(28, 12)))
    #expect(days.day(opening: "b") == nil)
    #expect(days.day(opening: "c") == Self.calendar.startOfDay(for: Self.date(29, 12)))
    #expect(days.day(opening: "d") == nil)
    #expect(days.day(opening: "e") == Self.calendar.startOfDay(for: Self.date(30, 12)))
  }

  @Test("A message without a date opens no day, nor breaks the one it is in")
  func undatedMessage() {
    let blocks = [
      Self.prompt("old", nil),
      Self.prompt("a", Self.date(29, 10)),
      Self.answer("undated", nil),
      Self.answer("b", Self.date(29, 11)),
    ]
    let days = Self.days(blocks)
    #expect(days.day(opening: "old") == nil)
    #expect(days.day(opening: "undated") == nil)
    #expect(days.day(opening: "a") != nil)
    #expect(days.day(opening: "b") == nil)
  }

  @Test("A tool call opens no day: the next message does")
  func toolsOpenNothing() {
    let blocks = [
      Self.prompt("a", Self.date(29, 23)),
      Self.tool("t", Self.date(30, 0, 1)),
      Self.answer("b", Self.date(30, 0, 2)),
    ]
    let days = Self.days(blocks)
    #expect(days.day(opening: "t") == nil)
    #expect(days.day(opening: "b") != nil)
  }

  @Test("Brought up to date from a block, the days are those of a full reading")
  func incremental() {
    let all = [
      Self.prompt("a", Self.date(28, 9)),
      Self.answer("b", Self.date(29, 9)),
      Self.prompt("c", Self.date(29, 10)),
      Self.answer("d", Self.date(30, 9)),
    ]
    for start in all.indices {
      var days = ConversationDays()
      days.calendar = Self.calendar
      days.update(Array(all.prefix(start)) + [Self.tool("x", nil)], from: 0)
      days.update(all, from: start)
      #expect(days == Self.days(all), "from \(start)")
    }
  }

  @Test("The separator says Today, Yesterday, or the date")
  func separatorLabel() {
    let now = Self.date(30, 14)
    #expect(DaySeparator.label(for: Self.date(30, 0), now: now, calendar: Self.calendar)
      == Text("Today", bundle: .module))
    #expect(DaySeparator.label(for: Self.date(29, 0), now: now, calendar: Self.calendar)
      == Text("Yesterday", bundle: .module))
    #expect(DaySeparator.label(for: Self.date(20, 0), now: now, calendar: Self.calendar)
      != Text("Yesterday", bundle: .module))
  }
}
