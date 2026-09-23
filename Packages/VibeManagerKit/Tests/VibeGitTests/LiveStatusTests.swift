import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

@Suite("Following a real repository as it changes outside the application")
struct LiveStatusTests {
  private func latest(
    _ path: String, in box: StateBox
  ) -> RepositoryStatusState? {
    box.states.last { $0.key.repositoryPath == path }
  }

  private func waitFor(
    _ box: StateBox, _ path: String, timeout: Duration = .seconds(5),
    _ condition: (RepositoryStatusState) -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let state = latest(path, in: box), condition(state) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  @Test("A write, an add, a commit and a checkout made elsewhere each reach the state")
  func externalChanges() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    let monitor = RepositoryStatusMonitor(
      reader: GitStatusReader(),
      events: FSEventsFileChangeObserver(latency: 0.05),
      limits: RepositoryStatusLimits(
        minimumInterval: .milliseconds(100), maximumInterval: .milliseconds(500)))
    let box = StateBox()
    let listener = Task {
      for await update in monitor.updates {
        if case .states(let states) = update { box.append(states) }
      }
    }
    defer { listener.cancel() }
    let session = WorkSession(name: "API", repositories: [RepositoryContext(path: repository)])
    let path = CanonicalPath.of(repository)

    await monitor.observe(session, repositories: [ObservedRepository(path: path)])
    #expect(await waitFor(box, path) { $0.phase == .fresh && $0.lastValid?.isClean == true })
    // FSEvents only reports what happens after its stream has started.
    try await Task.sleep(for: .milliseconds(300))

    try Data("changed\n".utf8).write(to: URL(fileURLWithPath: repository + "/README"))
    #expect(await waitFor(box, path) { $0.lastValid?.counts.unstaged == 1 })

    try await git(["add", "README"], in: repository)
    #expect(await waitFor(box, path) { $0.lastValid?.counts.staged == 1 })

    // A commit touches nothing in the working tree: only Git's own folder says it happened.
    try await git(["commit", "-q", "-m", "Change"], in: repository)
    #expect(await waitFor(box, path) { $0.lastValid?.isClean == true })

    try await git(["checkout", "-q", "-b", "feature"], in: repository)
    #expect(await waitFor(box, path) { $0.lastValid?.branch.branchName == "feature" })

    await monitor.stop()
  }
}

private final class StateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [RepositoryStatusState] = []

  var states: [RepositoryStatusState] { lock.withLock { stored } }

  func append(_ states: [RepositoryStatusState]) {
    lock.withLock { stored.append(contentsOf: states) }
  }
}
