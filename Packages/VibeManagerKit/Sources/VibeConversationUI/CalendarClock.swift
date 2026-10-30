import Foundation
import Observation

/// Today and the calendar the conversation reads its days in, read again at midnight and when the
/// time zone changes (#458): a separator says « Today » for today only, and the days are cut at
/// the midnights of where the user is.
@MainActor
@Observable
public final class CalendarClock {
  public static let shared = CalendarClock()

  public private(set) var now: Date
  public private(set) var calendar: Calendar
  @ObservationIgnored private let currentDate: @Sendable () -> Date
  @ObservationIgnored private let currentCalendar: @Sendable () -> Calendar
  @ObservationIgnored private var timeZoneChanges: [@MainActor () -> Void] = []

  init(
    center: NotificationCenter = .default, now: @escaping @Sendable () -> Date = { .now },
    calendar: @escaping @Sendable () -> Calendar = { .current }
  ) {
    currentDate = now
    currentCalendar = calendar
    self.now = now()
    self.calendar = calendar()
    // Posted on any thread: read again on the main actor.
    for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
      center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      }
    }
  }

  /// Runs `action` after the time zone changed, `calendar` already in the new one.
  func onTimeZoneChange(_ action: @escaping @MainActor () -> Void) {
    timeZoneChanges.append(action)
  }

  private func refresh() {
    now = currentDate()
    let calendar = currentCalendar()
    guard calendar != self.calendar else { return }
    let zoneChanged = calendar.timeZone != self.calendar.timeZone
    self.calendar = calendar
    if zoneChanged { timeZoneChanges.forEach { $0() } }
  }
}
