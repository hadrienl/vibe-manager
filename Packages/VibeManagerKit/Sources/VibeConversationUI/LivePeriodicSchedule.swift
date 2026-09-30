import SwiftUI

/// Once a second while the conversation is on screen, and never while it is not: the five
/// conversations kept mounted but hidden would otherwise go on redrawing their clocks (#255).
///
/// A schedule rather than a view that swaps its clock for a still text: the view keeps its
/// identity, and nothing moves in the layout when the conversation comes back on screen, where the
/// new environment starts it again with the time right at once.
struct LivePeriodicSchedule: TimelineSchedule {
  let start: Date
  let interval: TimeInterval
  let isLive: Bool

  init(from start: Date, by interval: TimeInterval, isLive: Bool) {
    self.start = start
    self.interval = interval
    self.isLive = isLive
  }

  func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    guard isLive else {
      // One date, the one the view is drawn at, then nothing.
      var sent = false
      return AnyIterator {
        guard !sent else { return nil }
        sent = true
        return startDate
      }
    }
    var periodic = PeriodicTimelineSchedule(from: start, by: interval)
      .entries(from: startDate, mode: mode).makeIterator()
    return AnyIterator { periodic.next() }
  }
}

extension EnvironmentValues {
  /// Whether the conversation the views belong to is the one on screen: a hidden one keeps its
  /// clocks still (#255).
  @Entry var conversationIsLive = true
}
