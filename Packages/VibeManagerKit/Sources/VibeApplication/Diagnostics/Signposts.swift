import os

/// Intervals for Instruments, under `com.hadrienl.VibeManager`, category `perf`. They cost nothing
/// while nothing records them, so they stay in every build.
public enum Signposts {
  public static let signposter = OSSignposter(
    subsystem: "com.hadrienl.VibeManager", category: "perf")

  /// Runs `body` inside an interval named `name`.
  public static func interval<Result>(
    _ name: StaticString,
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    defer { signposter.endInterval(name, state) }
    return try await body()
  }

  /// Runs `body` inside an interval named `name`, synchronously.
  public static func interval<Result>(
    _ name: StaticString,
    _ body: () throws -> Result
  ) rethrows -> Result {
    try signposter.withIntervalSignpost(name, id: signposter.makeSignpostID(), around: body)
  }

  /// An interval that ends somewhere else than where it began.
  public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
    signposter.beginInterval(name, id: signposter.makeSignpostID())
  }

  public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
    signposter.endInterval(name, state)
  }
}
