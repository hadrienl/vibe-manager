import Foundation
import SwiftUI
import Testing

@testable import VibeConversationUI

@Suite("Clocks that stop off screen (#255)")
struct LivePeriodicScheduleTests {
  private let start = Date(timeIntervalSinceReferenceDate: 1_000)

  @Test("On screen: a date every second")
  func live() {
    let dates = Array(
      AnySequence {
        LivePeriodicSchedule(from: start, by: 1, isLive: true).entries(from: start, mode: .normal)
      }.prefix(3))
    #expect(dates == [start, start + 1, start + 2])
  }

  @Test("Off screen: the date it is drawn at, then nothing")
  func still() {
    let dates = Array(
      AnySequence {
        LivePeriodicSchedule(from: start, by: 1, isLive: false).entries(
          from: start + 5, mode: .normal)
      }.prefix(3))
    #expect(dates == [start + 5])
  }
}
