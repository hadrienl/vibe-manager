/// How many times the few views that hold the window together had their `body` evaluated (#254).
///
/// Counted in development builds only, where `perf.bodyEvaluations` publishes the counts: a
/// transition of an agent in a hidden session must not evaluate the whole window again, and this
/// is how that is seen without Instruments. A release build counts nothing.
@MainActor
public enum BodyCounter {
  /// The views counted. A closed set, like every name the diagnostics log.
  public enum View: CaseIterable, Sendable {
    case rootView
    case sessionSidebar
    case sessionRow
    case sessionTerminalSlot
    case conversationView
  }

  private static var counts: [View: Int] = [:]

  /// Called at the top of a counted view's `body`: `let _ = BodyCounter.tick(.rootView)`.
  public static func tick(_ view: View) {
    #if DEBUG
      counts[view, default: 0] += 1
    #endif
  }

  /// The evaluations counted since the last call, and a fresh count.
  public static func drain() -> [View: Int] {
    defer { counts = [:] }
    return counts
  }

  /// The evaluations counted so far, left counting: for the tests.
  public static func count(of view: View) -> Int {
    counts[view] ?? 0
  }
}
