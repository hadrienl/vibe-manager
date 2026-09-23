import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Keeping the repositories of the session on screen read")
struct RepositoryStatusMonitorTests {
  private let session = WorkSession(
    name: "Refonte", repositories: [RepositoryContext(path: "/work/api")])

  private func makeMonitor(
    reader: ScriptedStatusReader,
    events: ManualFileChanges = ManualFileChanges(),
    transcripts: TableTranscriptSource? = nil,
    clock: any SessionClock = SystemSessionClock(),
    limits: RepositoryStatusLimits = RepositoryStatusLimits(
      minimumInterval: .milliseconds(80), maximumInterval: .milliseconds(200),
      lockGrace: .milliseconds(200))
  ) -> RepositoryStatusMonitor {
    RepositoryStatusMonitor(
      reader: reader, events: events, transcripts: transcripts, clock: clock, limits: limits)
  }

  @Test("Each repository is read once when it is first watched, and its changes attributed")
  func firstReading() async {
    let reader = ScriptedStatusReader()
    await reader.answer(
      "/work/api",
      entries: [
        WorkingTreeEntry(path: "Sources/A.swift", kind: .tracked(staged: nil, unstaged: .modified)),
        WorkingTreeEntry(path: "README.md", kind: .tracked(staged: .modified, unstaged: nil)),
        WorkingTreeEntry(path: "Generated/", kind: .untrackedDirectory),
      ])
    let transcripts = TableTranscriptSource(edited: [
      "/work/api/Sources/A.swift", "/work/api/Generated/Model.swift",
    ])
    let monitor = makeMonitor(reader: reader, transcripts: transcripts)
    let recorder = StatusUpdateRecorder.listening(to: monitor)

    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])

    #expect(await eventually { await recorder.latest("/work/api")?.phase == .fresh })
    let state = await recorder.latest("/work/api")
    #expect(state?.key == RepositoryStatusKey(sessionID: session.id, repositoryPath: "/work/api"))
    #expect(state?.lastValid?.counts == WorkingTreeCounts(staged: 1, unstaged: 1, untracked: 1))
    #expect(state?.entries.map(\.touchedByAgent) == [true, false, true])
    #expect(state?.unattributedCount == 1)
    #expect(await reader.readCount("/work/api") == 1)
  }

  @Test("Without a signal from the disk, nothing is read again")
  func noPolling() async throws {
    let reader = ScriptedStatusReader()
    let monitor = makeMonitor(reader: reader)
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { await reader.readCount("/work/api") == 1 })

    // Several times the longest pause: a timer, if there were one, would have fired.
    try await Task.sleep(for: .milliseconds(700))

    #expect(await reader.readCount("/work/api") == 1)
  }

  @Test("A burst of events costs two readings, not one per event")
  func burstCostsTwoReadings() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { events.openStreams == 1 })
    #expect(await eventually { await reader.readCount("/work/api") == 1 })
    try await Task.sleep(for: .milliseconds(250))

    // The reading the first event starts is held: every other event lands while it runs.
    await reader.hold()
    events.send(.changed(["/work/api/node_modules/package-0/index.js"]))
    #expect(await eventually { await reader.readCount("/work/api") == 2 })
    for index in 1..<1_000 {
      events.send(.changed(["/work/api/node_modules/package-\(index)/index.js"]))
    }
    try await Task.sleep(for: .milliseconds(200))
    await reader.release()
    try await Task.sleep(for: .milliseconds(600))

    // The first event starts a reading; the other 999 all land during it or its pause, and
    // together ask for exactly one more.
    #expect(await reader.readCount("/work/api") == 3)
  }

  @Test("A reading that found nothing new is not published again")
  func identicalReadingIsNotPublished() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { await recorder.latest("/work/api")?.phase == .fresh })
    #expect(await eventually { events.openStreams == 1 })
    try await Task.sleep(for: .milliseconds(250))
    let published = await recorder.publications(of: "/work/api")

    events.send(.changed(["/work/api/README.md"]))
    #expect(await eventually { await reader.readCount("/work/api") == 2 })
    try await Task.sleep(for: .milliseconds(100))

    #expect(await recorder.publications(of: "/work/api") == published)
  }

  @Test("A failure keeps what was true before, and the next success clears it")
  func failureKeepsLastValidState() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    let entry = WorkingTreeEntry(path: "a.txt", kind: .untracked)
    await reader.answer("/work/api", entries: [entry])
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { await recorder.latest("/work/api")?.phase == .fresh })
    #expect(await eventually { events.openStreams == 1 })
    try await Task.sleep(for: .milliseconds(250))

    await reader.answer("/work/api", with: .failure(.missing(path: "/work/api")))
    events.send(.rootChanged("/work/api"))
    #expect(
      await eventually {
        if case .failed(.missing, _) = await recorder.latest("/work/api")?.phase { return true }
        return false
      })
    #expect(await recorder.latest("/work/api")?.lastValid?.entries == [entry])

    try await Task.sleep(for: .milliseconds(250))
    await reader.answer("/work/api", entries: [])
    await monitor.refresh()
    #expect(await eventually { await recorder.latest("/work/api")?.phase == .fresh })
    #expect(await recorder.latest("/work/api")?.lastValid?.isClean == true)
  }

  @Test("A lock held a moment is not a failure; one held past the grace is said, with its age")
  func lockGrace() async {
    let reader = ScriptedStatusReader()
    let lock = IndexLock(path: "/work/api/.git/index.lock", since: Date())
    // The first reading sees the lock just taken, the next one long after: however slow the
    // machine, the grace has not run out at the first and has at the second.
    let clock = SteppingClock(lock.since, then: lock.since.addingTimeInterval(3_600))
    let monitor = makeMonitor(reader: reader, clock: clock)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    await reader.answer("/work/api", entries: [], lock: lock)

    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])

    #expect(await eventually { await recorder.states.contains { $0.phase == .fresh } })
    // No event will come for a lock nobody removes: the monitor reads once more when the grace
    // runs out, and only then says it.
    #expect(
      await eventually {
        guard case .failed(let issue, _) = await recorder.latest("/work/api")?.phase else {
          return false
        }
        return issue == .locked(lockPath: lock.path, since: lock.since)
      })
    #expect(await recorder.latest("/work/api")?.lastValid != nil)
  }

  @Test("A change in an agent's worktree reads the worktree, not the clone around it")
  func deepestRepositoryWins() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let clone = "/work/api"
    let worktree = "/work/api/.claude/worktrees/oauth"
    await reader.place(
      worktree, gitDirectory: "/work/api/.git/worktrees/oauth", commonDirectory: "/work/api/.git")
    let monitor = makeMonitor(reader: reader, events: events)
    await monitor.observe(
      session,
      repositories: [ObservedRepository(path: clone), ObservedRepository(path: worktree)])
    #expect(await eventually { events.openStreams == 1 })
    #expect(await eventually { await reader.readCount(worktree) == 1 })
    try await Task.sleep(for: .milliseconds(250))

    events.send(.changed([worktree + "/Sources/Token.swift"]))
    #expect(await eventually { await reader.readCount(worktree) == 2 })
    try await Task.sleep(for: .milliseconds(100))

    #expect(await reader.readCount(clone) == 1)
  }

  @Test("Git's objects are ignored; a branch that moves reads the repository and dates the report")
  func referencesAndObjects() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { events.openStreams == 1 })
    #expect(await eventually { await reader.readCount("/work/api") == 1 })
    try await Task.sleep(for: .milliseconds(250))

    events.send(.changed(["/work/api/.git/objects/ab/cdef0123"]))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await reader.readCount("/work/api") == 1)
    #expect(await recorder.outdatedReports == 0)

    events.send(
      .changed(["/work/api/.git/refs/heads/main", "/work/api/.git/logs/refs/heads/main"]))
    #expect(await eventually { await reader.readCount("/work/api") == 2 })
    #expect(await eventually { await recorder.outdatedReports == 1 })
  }

  @Test("A commit in a linked worktree is seen through its own git-dir, outside the worktree")
  func linkedWorktreeGitDirectory() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let worktree = "/work/trees/oauth"
    await reader.place(
      worktree, gitDirectory: "/work/api/.git/worktrees/oauth", commonDirectory: "/work/api/.git")
    let monitor = makeMonitor(reader: reader, events: events)
    await monitor.observe(session, repositories: [ObservedRepository(path: worktree)])
    #expect(await eventually { events.openStreams == 1 })
    #expect(
      events.watchedPaths.sorted() == [
        "/work/api/.git", "/work/api/.git/worktrees/oauth", "/work/trees/oauth",
      ])
    #expect(await eventually { await reader.readCount(worktree) == 1 })
    try await Task.sleep(for: .milliseconds(250))

    events.send(.changed(["/work/api/.git/worktrees/oauth/index"]))
    #expect(await eventually { await reader.readCount(worktree) == 2 })
  }

  @Test("A transcript that grows updates what is attributed, and dates the report")
  func transcriptGrowth() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let transcripts = TableTranscriptSource(directories: ["/transcripts/project"])
    await reader.answer(
      "/work/api", entries: [WorkingTreeEntry(path: "a.swift", kind: .untracked)])
    let monitor = makeMonitor(reader: reader, events: events, transcripts: transcripts)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    let session = WorkSession(
      name: "Refonte",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "5e9-abc"),
      repositories: [RepositoryContext(path: "/work/api")])
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { await recorder.latest("/work/api")?.unattributedCount == 1 })
    #expect(await eventually { events.openStreams == 1 })

    // Another session opened in the same folder writes its own transcript beside this one's.
    events.send(.changed(["/transcripts/project/other-session.jsonl"]))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await recorder.outdatedReports == 0)

    await transcripts.setEdited(["/work/api/a.swift"])
    events.send(.changed(["/transcripts/project/5e9-abc.jsonl"]))

    #expect(await eventually { await recorder.latest("/work/api")?.unattributedCount == 0 })
    #expect(await eventually { await recorder.outdatedReports == 1 })
    #expect(await reader.readCount("/work/api") == 1)
  }

  @Test("Never more than two readings at once, however many repositories")
  func concurrentReadings() async {
    let reader = ScriptedStatusReader()
    await reader.hold()
    let monitor = makeMonitor(reader: reader)
    let paths = (1...5).map { "/work/repo\($0)" }

    await monitor.observe(session, repositories: paths.map { ObservedRepository(path: $0) })
    #expect(await eventually { await reader.mostAtOnce == 2 })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await reader.mostAtOnce == 2)
    await reader.release()
    #expect(
      await eventually {
        var total = 0
        for path in paths { total += await reader.readCount(path) }
        return total == 5
      })
    #expect(await reader.mostAtOnce == 2)
  }

  @Test("Unfolding an untracked folder waits for a slot, like any other reading")
  func untrackedListingShareTheSlots() async {
    let reader = ScriptedStatusReader()
    await reader.hold()
    let monitor = makeMonitor(reader: reader)
    let paths = ["/work/api", "/work/web"]
    await monitor.observe(session, repositories: paths.map { ObservedRepository(path: $0) })
    #expect(await eventually { await reader.mostAtOnce == 2 })

    let key = RepositoryStatusKey(sessionID: session.id, repositoryPath: "/work/api")
    let listing = Task { await monitor.untrackedFiles(in: "Generated/", of: key) }
    try? await Task.sleep(for: .milliseconds(100))
    // Both slots are held by `git status`: the listing has not started.
    #expect(await reader.listings == 0)
    #expect(await reader.mostAtOnce == 2)

    await reader.release()
    let result = await listing.value
    #expect(
      (try? result.get())?.paths == [
        "Generated/file0.txt", "Generated/file1.txt", "Generated/file2.txt",
      ])
    #expect(await reader.mostAtOnce == 2)
  }

  @Test("Leaving the session marks its states unobserved, and a late reading lands on nothing")
  func stoppingObservation() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { await recorder.latest("/work/api")?.phase == .fresh })

    await reader.hold()
    await monitor.refresh()
    try await Task.sleep(for: .milliseconds(50))
    await monitor.stopObserving()
    await reader.release()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await recorder.latest("/work/api")?.phase == .unobserved)
    #expect(await recorder.latest("/work/api")?.lastValid != nil)
    #expect(await eventually { events.openStreams == 0 })
  }

  @Test("Another session in the same repository is named")
  func sharedRepository() async {
    let reader = ScriptedStatusReader()
    let monitor = makeMonitor(reader: reader)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    let other = SessionID()

    await monitor.observe(
      session, repositories: [ObservedRepository(path: "/work/api", sharedWith: [other])])

    #expect(await eventually { await recorder.latest("/work/api")?.sharedWith == [other] })
  }
}

extension RepositoryStatusMonitorTests {
  @Test("A newer list for the same session, landing mid-way, leaves no repository unread")
  func overlappingObservations() async {
    let reader = ScriptedStatusReader()
    let monitor = makeMonitor(reader: reader)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    let paths = ["/work/p", "/work/q", "/work/r"]

    async let wide: Void = monitor.observe(
      session, repositories: paths.map { ObservedRepository(path: $0) })
    async let narrow: Void = monitor.observe(
      session, repositories: [ObservedRepository(path: "/work/p")])
    _ = await (wide, narrow)
    await monitor.observe(session, repositories: paths.map { ObservedRepository(path: $0) })

    for path in paths {
      #expect(await eventually { await recorder.latest(path)?.phase == .fresh })
    }
  }

  @Test("A watch replaced by a new one reads again the repositories the old one watched")
  func replacedWatch() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(await eventually { events.openStreams == 1 })
    #expect(await eventually { await reader.readCount("/work/api") == 1 })

    // The old stream may have held back a change in /work/api when the new one opened.
    await monitor.observe(
      session,
      repositories: [ObservedRepository(path: "/work/api"), ObservedRepository(path: "/work/web")])

    #expect(await eventually { await reader.readCount("/work/api") == 2 })
    #expect(await eventually { await reader.readCount("/work/web") == 1 })
    try await Task.sleep(for: .milliseconds(250))
    #expect(await reader.readCount("/work/web") == 1)
  }

  @Test("A reference moved by the clone reads the worktree of it that is watched too")
  func sharedReferences() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let worktree = "/work/trees/oauth"
    await reader.place(
      worktree, gitDirectory: "/work/api/.git/worktrees/oauth", commonDirectory: "/work/api/.git")
    let monitor = makeMonitor(reader: reader, events: events)
    await monitor.observe(
      session,
      repositories: [ObservedRepository(path: "/work/api"), ObservedRepository(path: worktree)])
    #expect(await eventually { events.openStreams == 1 })
    #expect(await eventually { await reader.readCount(worktree) == 1 })
    try await Task.sleep(for: .milliseconds(250))

    events.send(.changed(["/work/api/.git/refs/remotes/origin/oauth"]))

    #expect(await eventually { await reader.readCount(worktree) == 2 })
    #expect(await eventually { await reader.readCount("/work/api") == 2 })
  }

  @Test("Once stopped, nothing is watched or read again, whatever arrives late")
  func stoppedMonitorStaysStopped() async throws {
    let reader = ScriptedStatusReader()
    let events = ManualFileChanges()
    let monitor = makeMonitor(reader: reader, events: events)

    await monitor.stop()
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    await monitor.refresh()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await reader.readCount("/work/api") == 0)
    #expect(events.openStreams == 0)
  }

  @Test("A timeout that repeats is one failure, dated from the first")
  func repeatedTimeout() async throws {
    let reader = ScriptedStatusReader()
    let monitor = makeMonitor(reader: reader)
    let recorder = StatusUpdateRecorder.listening(to: monitor)
    await reader.answer("/work/api", with: .failure(.timedOut(after: .milliseconds(30_010))))
    await monitor.observe(session, repositories: [ObservedRepository(path: "/work/api")])
    #expect(
      await eventually {
        if case .failed(.timedOut, _) = await recorder.latest("/work/api")?.phase { return true }
        return false
      })
    let published = await recorder.publications(of: "/work/api")
    try await Task.sleep(for: .milliseconds(250))

    await reader.answer("/work/api", with: .failure(.timedOut(after: .milliseconds(30_030))))
    await monitor.refresh()
    #expect(await eventually { await reader.readCount("/work/api") == 2 })
    try await Task.sleep(for: .milliseconds(100))

    #expect(await recorder.publications(of: "/work/api") == published)
  }
}

@Suite("Why a repository could not be read")
struct RepositoryStatusIssueTests {
  @Test("Git's refusals are recognised, whatever else they say")
  func classification() {
    #expect(
      RepositoryStatusIssue.classify(
        errorOutput: "fatal: detected dubious ownership in repository at '/x'", path: "/x")
        == .unsafeRepository(path: "/x"))
    #expect(
      RepositoryStatusIssue.classify(
        errorOutput: "fatal: not a git repository (or any of the parent directories): .git",
        path: "/x") == .notARepository(path: "/x"))
    #expect(
      RepositoryStatusIssue.classify(errorOutput: "error: Permission denied", path: "/x")
        == .permissionDenied(path: "/x"))
    #expect(
      RepositoryStatusIssue.classify(errorOutput: "fatal: bad object HEAD\nmore", path: "/x")
        == .failed(summary: "fatal: bad object HEAD"))
  }

  @Test("A command to copy is escaped for the shell, and only offered where it helps")
  func copyableCommands() {
    #expect(
      RepositoryStatusIssue.unsafeRepository(path: "/Users/a/l'API (v2)").copyableCommand
        == #"git config --global --add safe.directory '/Users/a/l'\''API (v2)'"#)
    #expect(
      RepositoryStatusIssue.locked(lockPath: "/r/.git/index.lock", since: Date()).copyableCommand
        == "rm /r/.git/index.lock")
    #expect(RepositoryStatusIssue.missing(path: "/r").copyableCommand == nil)
  }
}
