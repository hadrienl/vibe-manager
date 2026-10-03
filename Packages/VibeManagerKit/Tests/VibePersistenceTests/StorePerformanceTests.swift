import Foundation
import Testing
import VibeDomain

@testable import VibePersistence

/// The measures #253 asks for, on a store the size of a real one: run by hand, in Release, never
/// by the CI (`VIBE_PERF_TESTS=1 swift test -c release --filter StorePerformanceTests`). Times
/// are printed, not asserted: a shared runner's clock decides nothing.
@Suite(
  "How long the session store takes (#253)",
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_PERF_TESTS"] == "1"))
struct StorePerformanceTests {
  /// About the size of a real store: 250 sessions, some 1,1 kB each.
  private static let sessionCount = 250
  private static let targetBytes = 275_000

  private func storeURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeStorePerformance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("sessions.json")
  }

  private func session(_ index: Int, padding: String) -> WorkSession {
    let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 600)
    return WorkSession(
      name: "Session \(index)",
      initialPrompt: "Fix the thing number \(index). " + padding,
      agent: SessionAgentConfiguration(
        providerID: index.isMultiple(of: 3) ? "codex" : "claude-code", modelID: "opus",
        resumeIdentifier: UUID().uuidString),
      appearance: SessionAppearance(symbolName: "hammer.fill", colorHex: "#0A84FF"),
      status: index.isMultiple(of: 4) ? .archived : .closed,
      createdAt: date, updatedAt: date, closedAt: date,
      archivedAt: index.isMultiple(of: 4) ? date : nil, startedAt: date,
      repositories: [
        RepositoryContext(
          path: "/Users/me/Projects/repo-\(index % 12)",
          git: GitSnapshot(
            repositoryRootPath: "/Users/me/Projects/repo-\(index % 12)",
            worktreePath: "/Users/me/Projects/repo-\(index % 12)-wt-\(index)",
            branchName: "feat/\(index)-work", headRevision: "abc\(index)", isDirty: false,
            capturedAt: date))
      ])
  }

  /// A store of `sessionCount` sessions, padded to about `targetBytes`.
  private func makeStore() throws -> (URL, [WorkSession], Int) {
    let url = try storeURL()
    var padding = ""
    var sessions = (0..<Self.sessionCount).map { session($0, padding: padding) }
    var data = try SessionStoreCodec().encode(sessions: sessions)
    let missing = max(0, Self.targetBytes - data.count) / Self.sessionCount
    padding = String(repeating: "x", count: missing)
    sessions = (0..<Self.sessionCount).map { session($0, padding: padding) }
    data = try SessionStoreCodec().encode(sessions: sessions)
    try data.write(to: url)
    return (url, sessions, data.count)
  }

  private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
  }

  @Test("`mutate` on a store of 250 sessions, and a restoration of thirty")
  func measure() async throws {
    let (url, sessions, size) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repository = FileSessionRepository(storeURL: url)
    _ = try await repository.sessions()

    let clock = ContinuousClock()
    var durations: [Double] = []
    for round in 0..<200 {
      let id = sessions[round % sessions.count].id
      let elapsed = try await clock.measure {
        _ = try await repository.mutate(id: id) { $0.name = "Renamed \(round)" }
      }
      durations.append(
        Double(elapsed.components.seconds) * 1000
          + Double(elapsed.components.attoseconds) / 1e15)
    }
    durations.sort()

    // Where the time goes: encoding the whole document, and writing it for good.
    var encodes: [Double] = []
    var writes: [Double] = []
    let scratch = url.deletingLastPathComponent().appendingPathComponent("scratch.json")
    for _ in 0..<50 {
      var data = Data()
      let encoded = try clock.measure { data = try SessionStoreCodec().encode(sessions: sessions) }
      let written = try clock.measure { try data.write(to: scratch, options: .atomic) }
      encodes.append(Double(encoded.components.attoseconds) / 1e15)
      writes.append(Double(written.components.attoseconds) / 1e15)
    }
    encodes.sort()
    writes.sort()

    // What a launch does for each session it restores, on a store opened cold.
    let launched = FileSessionRepository(storeURL: url)
    for session in sessions.prefix(30) {
      _ = try await launched.session(id: session.id)?.name
      _ = try await launched.session(id: session.id)
      _ = try await launched.mutate(id: session.id) { $0.agent?.resumeIdentifier = "resumed" }
    }
    let decodes = await launched.decodeCount

    print(
      String(
        format:
          "STORE-PERF sessions=%d bytes=%d mutate p50=%.2fms p95=%.2fms max=%.2fms; "
          + "encode p50=%.2fms; atomic write p50=%.2fms; restoration of 30 decodes=%d",
        sessions.count, size, percentile(durations, 0.5), percentile(durations, 0.95),
        durations.last ?? 0, percentile(encodes, 0.5), percentile(writes, 0.5), decodes))
    #expect(decodes <= 1)
  }
}
