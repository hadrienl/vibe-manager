import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

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

  @Test("Past midnight, the clock reads the new day: Today's separator says Yesterday")
  @MainActor
  func midnight() async {
    let center = NotificationCenter()
    let now = Locked(Self.date(30, 23, 59))
    let clock = CalendarClock(center: center, now: { now.value }, calendar: { Self.calendar })
    let day = Self.calendar.startOfDay(for: Self.date(30, 12))
    #expect(
      DaySeparator.label(for: day, now: clock.now, calendar: clock.calendar)
        == Text("Today", bundle: .module))

    now.value = Self.date(31, 0, 0)
    center.post(name: .NSCalendarDayChanged, object: nil)
    await until { clock.now == Self.date(31, 0, 0) }
    #expect(
      DaySeparator.label(for: day, now: clock.now, calendar: clock.calendar)
        == Text("Yesterday", bundle: .module))
  }

  @Test("A conversation gone leaves the clock nothing to run")
  @MainActor
  func closedConversation() {
    let clock = CalendarClock(
      center: NotificationCenter(), now: { Self.date(30, 12) }, calendar: { Self.calendar })
    var closed: ConversationModel? = ConversationModel(sessionID: SessionID(), clock: clock)
    #expect(clock.timeZoneChangeCount == 1)
    closed = nil
    let open = ConversationModel(sessionID: SessionID(), clock: clock)
    #expect(closed == nil)
    #expect(clock.timeZoneChangeCount == 1)
    withExtendedLifetime(open) {}
  }

  @Test("When the time zone changes, the days are cut again at its midnights")
  @MainActor
  func timeZoneChange() async {
    let center = NotificationCenter()
    let paris = Self.calendar
    var newYork = paris
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let calendar = Locked(paris)
    let clock = CalendarClock(
      center: center, now: { Self.date(30, 12) }, calendar: { calendar.value })
    let model = ConversationModel(sessionID: SessionID(), clock: clock)
    // 23:00 and 01:00 in Paris, two days; 18:00 and 20:00 in New York, the same one.
    let entries = [
      ConversationEntry(
        id: "a", date: Self.date(29, 23), content: .userPrompt("a", attachments: [])),
      ConversationEntry(id: "b", date: Self.date(30, 1), content: .agentText("b")),
    ]
    var snapshot = ConversationSnapshot(entries: entries, availability: .available)
    snapshot.revision = 1
    model.received(snapshot)
    #expect(model.days.day(opening: "b") != nil)

    calendar.value = newYork
    center.post(name: .NSSystemTimeZoneDidChange, object: nil)
    await until { model.days.day(opening: "b") == nil }
    var expected = ConversationDays()
    expected.calendar = newYork
    expected.update(model.blocks, from: 0)
    #expect(model.days == expected)
  }

  @Test("The first message of a day and its separator are one row of the list")
  @MainActor
  func separatorInTheRow() {
    let model = ConversationModel(sessionID: SessionID())
    var snapshot = ConversationSnapshot(
      entries: [ConversationEntry(id: "a", date: .now, content: .agentText("Hello"))],
      availability: .available)
    snapshot.revision = 1
    model.received(snapshot)
    let block = model.blocks[0]
    #expect(model.days.day(opening: block.id) != nil)
    let row = NSHostingView(rootView: BlockRow(block: block, model: model, spacing: 8))
    let alone = NSHostingView(rootView: BlockView(block: block, model: model))
    #expect(row.fittingSize.height > alone.fittingSize.height)
  }

  @Test("The time of a prompt opens its full date towards the conversation's middle")
  func promptTooltipSide() {
    #expect(UserPromptView.tooltipSide(.bubbles) == .leading)
    #expect(UserPromptView.tooltipSide(.lines) == .trailing)
  }
}

/// A value the clock's closures read, changed by the test.
private final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// Waits for a state the notification brings on the main actor: the ceiling is only there for a
/// test that would never reach it.
@MainActor
private func until(_ condition: () -> Bool) async {
  for _ in 0..<10_000 where !condition() { await Task.yield() }
}
