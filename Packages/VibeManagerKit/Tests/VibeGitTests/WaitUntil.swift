import Testing

/// Waits for a state, never for a deadline: what a test waits for lands through tasks that a CI
/// runner whose cooperative pool is saturated can leave unscheduled for seconds, or freeze with the
/// whole process. Only the time this wait itself ran is counted — a wake-up far later than asked
/// is a stall, not waiting — and the bound, far beyond what the slowest runner needs, is only
/// there so that a state never reached is named at the line that waited for it, rather than the
/// suite's time limit saying nothing.
///
/// Returns whether the state was reached, for a test that has more to say when it was not.
@discardableResult
func waitUntil(
  _ what: String,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: () async -> Bool
) async -> Bool {
  let poll = Duration.milliseconds(10)
  let clock = ContinuousClock()
  var waited = Duration.zero
  while !(await condition()) {
    guard waited < .seconds(60) else {
      Issue.record("Never reached: \(what).", sourceLocation: sourceLocation)
      return false
    }
    let asleep = clock.now
    do {
      try await Task.sleep(for: poll)
    } catch {
      Issue.record("Cancelled while waiting: \(what).", sourceLocation: sourceLocation)
      return false
    }
    waited += min(clock.now - asleep, poll * 5)
  }
  return true
}
