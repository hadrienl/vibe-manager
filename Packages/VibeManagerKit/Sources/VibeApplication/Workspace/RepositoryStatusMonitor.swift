import Foundation
import VibeDomain

/// One repository of one session: the key a state is published under.
public struct RepositoryStatusKey: Hashable, Sendable {
  public let sessionID: SessionID
  /// `RepositoryBranchReport.path`: the canonical root of the repository.
  public let repositoryPath: String

  public init(sessionID: SessionID, repositoryPath: String) {
    self.sessionID = sessionID
    self.repositoryPath = repositoryPath
  }
}

/// An entry, and whether the session's own transcript names it.
///
/// `git status` says a file changed, never who changed it. The transcript says which files the
/// agent's editing tools wrote: a file it names is this agent's work. One it does not name is not
/// someone else's — a command the agent ran may have written it — so it is said to be unattributed,
/// never attributed to another session.
public struct AttributedEntry: Hashable, Sendable, Identifiable {
  public let entry: WorkingTreeEntry
  public let touchedByAgent: Bool

  public init(entry: WorkingTreeEntry, touchedByAgent: Bool) {
    self.entry = entry
    self.touchedByAgent = touchedByAgent
  }

  public var id: String { entry.id }
}

/// What is known of one repository of the session on screen.
public struct RepositoryStatusState: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// Being read for the first time: nothing is known yet.
    case refreshing
    /// Watched, and the last reading succeeded.
    case fresh
    /// The last reading failed. `lastValid` is still what was true before.
    case failed(RepositoryStatusIssue, since: Date)
    /// No longer watched: `lastValid` is what was true when the session was last on screen.
    case unobserved
  }

  public let key: RepositoryStatusKey
  /// Never cleared by a failure.
  public let lastValid: WorkingTreeStatus?
  /// `lastValid`'s entries, attributed for this session.
  public let entries: [AttributedEntry]
  public let phase: Phase
  /// Other sessions working in the same repository: the entries not attributed to this agent may
  /// be theirs.
  public let sharedWith: [SessionID]

  public init(
    key: RepositoryStatusKey,
    lastValid: WorkingTreeStatus?,
    entries: [AttributedEntry],
    phase: Phase,
    sharedWith: [SessionID]
  ) {
    self.key = key
    self.lastValid = lastValid
    self.entries = entries
    self.phase = phase
    self.sharedWith = sharedWith
  }

  /// How many changed entries the transcript does not name.
  public var unattributedCount: Int {
    entries.filter { !$0.touchedByAgent }.count
  }

  /// The same state, whatever the clock said when each was read.
  func hasSameContent(as other: RepositoryStatusState) -> Bool {
    guard key == other.key, phase == other.phase, sharedWith == other.sharedWith,
      entries == other.entries
    else { return false }
    switch (lastValid, other.lastValid) {
    case (nil, nil): return true
    case (let lhs?, let rhs?): return lhs.hasSameContent(as: rhs)
    default: return false
    }
  }
}

/// A repository to watch for the session on screen, as its branch report found it.
public struct ObservedRepository: Hashable, Sendable {
  public let path: String
  public let sharedWith: [SessionID]

  public init(path: String, sharedWith: [SessionID] = []) {
    self.path = path
    self.sharedWith = sharedWith
  }
}

public enum RepositoryStatusUpdate: Equatable, Sendable {
  /// Only the states that changed.
  case states([RepositoryStatusState])
  /// The transcript grew, or a branch moved: the branch report of this session is out of date.
  case branchReportOutdated(SessionID)
}

public struct RepositoryStatusLimits: Sendable {
  public var maximumEntries: Int
  public var minimumInterval: Duration
  public var maximumInterval: Duration
  /// How long another Git process may hold the index before it is said.
  public var lockGrace: Duration
  public var concurrentReads: Int
  /// The files of one unfolded untracked folder kept for the list; the rest are counted.
  public var maximumUntrackedFiles: Int

  public init(
    maximumEntries: Int = 5_000,
    minimumInterval: Duration = .seconds(1),
    maximumInterval: Duration = .seconds(15),
    lockGrace: Duration = .seconds(10),
    concurrentReads: Int = 2,
    maximumUntrackedFiles: Int = 1_000
  ) {
    self.maximumEntries = maximumEntries
    self.minimumInterval = minimumInterval
    self.maximumInterval = maximumInterval
    self.lockGrace = lockGrace
    self.concurrentReads = max(1, concurrentReads)
    self.maximumUntrackedFiles = max(1, maximumUntrackedFiles)
  }
}

/// A transcript, both read and located.
public typealias SessionTranscriptSource = SessionTranscriptLocating & SessionTranscriptReading

/// Keeps the repositories of the session on screen read, and only when the disk says so.
///
/// No timer reads a repository. The file system wakes a repository up — its folder, its
/// `git-dir`, the references its worktrees share — and `git status` confirms: one reading at a
/// time per repository, one more for whatever arrived during it, and a pause after each that
/// grows with how long the reading took. A repository that answers in 3 s is never read more than
/// once every 6 s, and a burst of ten thousand events costs two readings.
///
/// Everything happens here, off the main actor, and only the states that changed are published.
public actor RepositoryStatusMonitor {
  public nonisolated let updates: AsyncStream<RepositoryStatusUpdate>
  private let continuation: AsyncStream<RepositoryStatusUpdate>.Continuation

  private let reader: any RepositoryStatusReading
  private let events: any FileChangeObserving
  private let transcripts: (any SessionTranscriptSource)?
  private let clock: any SessionClock
  private let sleep: @Sendable (Duration) async throws -> Void
  private let limits: RepositoryStatusLimits

  private struct Watched {
    let path: String
    var sharedWith: [SessionID]
    var directories: GitDirectories?
    var lastValid: WorkingTreeStatus?
    var phase: RepositoryStatusState.Phase = .refreshing
    var isReading = false
    var isCooling = false
    var isPending = false
    var lastDuration: Duration = .zero
    var lockCheck: Task<Void, Never>?
  }

  private enum Target {
    case root(String)
    /// `sharers`: the other watched repositories whose references live in this same folder — a
    /// clone and a worktree of it — read again when a reference moves.
    case gitDirectory(String, sharesCommonDirectory: Bool, sharers: [String])
    case commonDirectory([String])
    case transcript
  }

  private var session: WorkSession?
  private var repositories: [String: Watched] = [:]
  private var editedPaths: Set<String> = []
  private var transcriptDirectories: [String] = []
  private var published: [RepositoryStatusKey: RepositoryStatusState] = [:]
  private var targets: [(prefix: String, target: Target)] = []
  private var watchedPaths: [String] = []
  private var watchTask: Task<Void, Never>?
  /// Bumped each time the session on screen changes: a reading that started for the previous one
  /// lands on nothing.
  private var generation = 0

  /// Set by `stop()`: a report read late on the way out must not open streams again.
  private var isStopped = false

  private var activeReads = 0
  private var waitingReads: [CheckedContinuation<Void, Never>] = []

  public init(
    reader: any RepositoryStatusReading,
    events: any FileChangeObserving,
    transcripts: (any SessionTranscriptSource)? = nil,
    clock: any SessionClock = SystemSessionClock(),
    limits: RepositoryStatusLimits = RepositoryStatusLimits(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.reader = reader
    self.events = events
    self.transcripts = transcripts
    self.clock = clock
    self.limits = limits
    self.sleep = sleep
    (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
  }

  // MARK: - What is observed

  /// Watches the repositories of `session`, as its branch report found them. Called again with
  /// the same session, it only adds and drops what changed: a repository already watched is not
  /// read again for being named twice.
  public func observe(_ session: WorkSession, repositories observed: [ObservedRepository]) async {
    guard !isStopped else { return }
    if self.session?.id != session.id {
      endObservation()
    }
    self.session = session
    let generation = generation

    if let transcripts {
      let activity = await transcripts.activity(for: session)
      let directories = await transcripts.transcriptDirectories(for: session)
      guard generation == self.generation else { return }
      editedPaths = Set((activity?.editedPaths ?? []).map(CanonicalPath.of))
      transcriptDirectories = directories.map(CanonicalPath.of)
    }

    var wanted: [String: ObservedRepository] = [:]
    for repository in observed {
      wanted[CanonicalPath.of(repository.path)] = repository
    }

    // Dropped from the report: said to be no longer watched, and forgotten.
    var dropped: [RepositoryStatusState] = []
    for path in repositories.keys where wanted[path] == nil {
      repositories[path]?.lockCheck?.cancel()
      repositories[path] = nil
      let key = RepositoryStatusKey(sessionID: session.id, repositoryPath: path)
      if let state = published.removeValue(forKey: key) {
        dropped.append(state.with(phase: .unobserved))
      }
    }
    if !dropped.isEmpty { continuation.yield(.states(dropped)) }

    var added: [String] = []
    for (path, repository) in wanted {
      if repositories[path] != nil {
        repositories[path]?.sharedWith = repository.sharedWith
      } else {
        repositories[path] = Watched(path: path, sharedWith: repository.sharedWith)
        added.append(path)
      }
    }

    for path in added.sorted() {
      let directories = await reader.gitDirectories(atPath: path)
      guard generation == self.generation else { return }
      // Dropped meanwhile by a newer call for the same session: the others still need reading.
      guard repositories[path] != nil else { continue }
      place(path, directories)
      startRead(path)
    }

    publishAll()
    rewatch()
  }

  /// Stops watching. The states stay with whoever holds them, marked as no longer watched.
  ///
  /// With `keep`, a session already being watched is left alone: the caller moved on to it, and a
  /// stop that arrives after its first `observe` must not undo it.
  public func stopObserving(unless keep: SessionID? = nil) {
    if let keep, session?.id == keep { return }
    endObservation()
  }

  /// Reads every watched repository again now, whatever pause it was in: the user asked, or came
  /// back to the application, or an agent just stopped.
  public func refresh() {
    guard !isStopped else { return }
    for path in repositories.keys {
      repositories[path]?.isCooling = false
      startRead(path)
    }
  }

  /// Stops watching for good, and closes `updates`.
  public func stop() {
    isStopped = true
    endObservation()
    continuation.finish()
  }

  private func endObservation() {
    generation += 1
    watchTask?.cancel()
    watchTask = nil
    watchedPaths = []
    targets = []
    for watched in repositories.values { watched.lockCheck?.cancel() }
    repositories = [:]
    editedPaths = []
    transcriptDirectories = []
    let unobserved = published.values.map { $0.with(phase: .unobserved) }
    published = [:]
    session = nil
    if !unobserved.isEmpty { continuation.yield(.states(unobserved)) }
  }

  // MARK: - Reading

  private func startRead(_ path: String) {
    guard !isStopped, var watched = repositories[path] else { return }
    guard !watched.isReading, !watched.isCooling else {
      repositories[path]?.isPending = true
      return
    }
    watched.isReading = true
    watched.isPending = false
    repositories[path] = watched
    let generation = generation
    Task { await self.read(path, generation: generation) }
  }

  private func read(_ path: String, generation: Int) async {
    await acquireReadSlot()
    guard generation == self.generation, repositories[path] != nil else {
      releaseReadSlot()
      return
    }
    let result = await reader.status(atPath: path, limit: limits.maximumEntries)
    releaseReadSlot()
    guard generation == self.generation, var watched = repositories[path] else { return }

    watched.isReading = false
    let now = clock.now()
    switch result {
    case .success(let status):
      if watched.directories == nil {
        // Unreadable when it was added — a volume away, a permission since granted. Without its
        // `git-dir`, a commit would never be seen.
        Task { await self.resolveDirectories(path, generation: generation) }
      }
      watched.lastValid = status
      watched.lastDuration = status.duration
      watched.lockCheck?.cancel()
      watched.lockCheck = nil
      if let lock = status.indexLock {
        let held = now.timeIntervalSince(lock.since)
        if held >= limits.lockGrace.timeInterval {
          watched.phase = watched.phase.keepingSince(
            .locked(lockPath: lock.path, since: lock.since), now: now)
        } else {
          // Nothing is said yet: most locks last a second. One more reading is set for the moment
          // the grace runs out, because an abandoned lock is removed by nobody and no event would
          // ever come to say it is still there.
          watched.phase = .fresh
          watched.lockCheck = scheduleLockCheck(
            path, after: limits.lockGrace.timeInterval - held, generation: generation)
        }
      } else {
        watched.phase = .fresh
      }
    case .failure(let issue):
      if case .timedOut = issue {
        watched.lastDuration = limits.maximumInterval
      }
      watched.phase = watched.phase.keepingSince(issue, now: now)
    }
    watched.isCooling = true
    repositories[path] = watched
    publish(path)

    let pause = min(max(limits.minimumInterval, watched.lastDuration * 2), limits.maximumInterval)
    Task {
      try? await sleep(pause)
      self.endPause(path, generation: generation)
    }
  }

  /// The files of an untracked folder, read when someone unfolds it — through the same slots as
  /// `git status`, so that unfolding a folder never makes a third Git run beside two readings.
  public func untrackedFiles(in directory: String, of key: RepositoryStatusKey) async -> Result<
    UntrackedListing, RepositoryStatusIssue
  > {
    guard !isStopped else {
      return .failure(.failed(summary: "The repositories are no longer read."))
    }
    await acquireReadSlot()
    let result = await reader.untrackedFiles(
      in: directory, atPath: key.repositoryPath, limit: limits.maximumUntrackedFiles)
    releaseReadSlot()
    return result
  }

  private func place(_ path: String, _ directories: Result<GitDirectories, RepositoryStatusIssue>) {
    guard case .success(let found) = directories else { return }
    repositories[path]?.directories = GitDirectories(
      gitDirectory: CanonicalPath.of(found.gitDirectory),
      commonDirectory: CanonicalPath.of(found.commonDirectory))
  }

  private func resolveDirectories(_ path: String, generation: Int) async {
    let directories = await reader.gitDirectories(atPath: path)
    guard generation == self.generation, repositories[path]?.directories == nil else { return }
    place(path, directories)
    if repositories[path]?.directories != nil { rewatch() }
  }

  private func endPause(_ path: String, generation: Int) {
    guard generation == self.generation, repositories[path]?.isCooling == true else { return }
    repositories[path]?.isCooling = false
    if repositories[path]?.isPending == true {
      startRead(path)
    }
  }

  private func scheduleLockCheck(_ path: String, after seconds: TimeInterval, generation: Int)
    -> Task<Void, Never>
  {
    Task {
      try? await sleep(.milliseconds(Int(max(0, seconds) * 1_000) + 50))
      guard !Task.isCancelled else { return }
      self.lockCheckDue(path, generation: generation)
    }
  }

  private func lockCheckDue(_ path: String, generation: Int) {
    guard generation == self.generation else { return }
    startRead(path)
  }

  private func markDirty(_ path: String) {
    guard repositories[path] != nil else { return }
    startRead(path)
  }

  private func acquireReadSlot() async {
    if activeReads < limits.concurrentReads {
      activeReads += 1
      return
    }
    await withCheckedContinuation { waitingReads.append($0) }
  }

  private func releaseReadSlot() {
    if waitingReads.isEmpty {
      activeReads -= 1
    } else {
      // The slot passes straight to the next reading: the count does not move.
      waitingReads.removeFirst().resume()
    }
  }

  // MARK: - Publishing

  private func state(of watched: Watched, in session: SessionID) -> RepositoryStatusState {
    let entries = (watched.lastValid?.entries ?? []).map { entry in
      AttributedEntry(entry: entry, touchedByAgent: isEdited(entry, in: watched.path))
    }
    return RepositoryStatusState(
      key: RepositoryStatusKey(sessionID: session, repositoryPath: watched.path),
      lastValid: watched.lastValid,
      entries: entries,
      phase: watched.phase,
      sharedWith: watched.sharedWith
    )
  }

  private func isEdited(_ entry: WorkingTreeEntry, in root: String) -> Bool {
    let absolute = (root as NSString).appendingPathComponent(entry.path)
    if case .untrackedDirectory = entry.kind {
      let prefix = absolute.hasSuffix("/") ? absolute : absolute + "/"
      return editedPaths.contains { $0.hasPrefix(prefix) }
    }
    if editedPaths.contains(absolute) { return true }
    if case .tracked(.renamed(let from, _)?, _) = entry.kind {
      return editedPaths.contains((root as NSString).appendingPathComponent(from))
    }
    return false
  }

  private func publish(_ path: String) {
    guard let session, let watched = repositories[path] else { return }
    let state = state(of: watched, in: session.id)
    if let previous = published[state.key], previous.hasSameContent(as: state) {
      // Nothing moved but the clock: kept quietly, so the next comparison is against the latest.
      published[state.key] = state
      return
    }
    published[state.key] = state
    continuation.yield(.states([state]))
  }

  private func publishAll() {
    guard let session else { return }
    var changed: [RepositoryStatusState] = []
    for watched in repositories.values.sorted(by: { $0.path < $1.path }) {
      let state = state(of: watched, in: session.id)
      if let previous = published[state.key], previous.hasSameContent(as: state) { continue }
      published[state.key] = state
      changed.append(state)
    }
    if !changed.isEmpty { continuation.yield(.states(changed)) }
  }

  // MARK: - Watching

  private func rewatch() {
    var routes: [(prefix: String, target: Target)] = []
    var commonOwners: [String: [String]] = [:]
    for watched in repositories.values {
      guard let directories = watched.directories else { continue }
      commonOwners[directories.commonDirectory, default: []].append(watched.path)
    }
    for watched in repositories.values {
      routes.append((watched.path, .root(watched.path)))
      guard let directories = watched.directories else { continue }
      let shares = directories.gitDirectory == directories.commonDirectory
      let sharers = (commonOwners[directories.commonDirectory] ?? []).filter {
        $0 != watched.path
      }
      routes.append(
        (
          directories.gitDirectory,
          .gitDirectory(watched.path, sharesCommonDirectory: shares, sharers: sharers)
        ))
    }
    for (common, owners) in commonOwners
    where !routes.contains(where: { $0.prefix == common }) {
      routes.append((common, .commonDirectory(owners.sorted())))
    }
    for directory in transcriptDirectories {
      routes.append((directory, .transcript))
    }
    // The deepest folder wins: an agent's worktree under `.claude/worktrees` belongs to itself,
    // and writing in it must not read the clone that happens to contain it.
    targets = routes.sorted { $0.prefix.count > $1.prefix.count }

    let paths = Array(Set(routes.map(\.prefix))).sorted()
    guard paths != watchedPaths else { return }
    let previouslyWatched = watchTask == nil ? [] : Set(watchedPaths)
    watchedPaths = paths
    watchTask?.cancel()
    // A stream that is closed is never flushed, and the next one starts from now: what the old one
    // held back, or what happened between the two, is gone. The repositories it watched are read
    // once more rather than trusted.
    for path in repositories.keys.sorted() where previouslyWatched.contains(path) {
      markDirty(path)
    }
    guard !paths.isEmpty else {
      watchTask = nil
      return
    }
    let stream = events.signals(for: paths)
    let generation = generation
    watchTask = Task { [weak self] in
      for await signal in stream {
        guard let self else { return }
        await self.handle(signal, generation: generation)
      }
    }
  }

  private func handle(_ signal: FileChangeSignal, generation: Int) async {
    guard generation == self.generation, let session else { return }
    var dirty: Set<String> = []
    var branchesMoved = false
    var transcriptGrew = false

    switch signal {
    case .mustRescan:
      dirty = Set(repositories.keys)
      branchesMoved = true
      transcriptGrew = !transcriptDirectories.isEmpty
    case .rootChanged(let path):
      let moved = Self.comparable(path)
      for root in repositories.keys where root == moved || root.hasPrefix(moved + "/") {
        dirty.insert(root)
      }
    case .changed(let paths):
      for path in paths {
        route(
          Self.comparable(path), dirty: &dirty, branchesMoved: &branchesMoved,
          transcriptGrew: &transcriptGrew)
      }
    }

    for path in dirty.sorted() {
      markDirty(path)
    }
    if transcriptGrew, let transcripts {
      let activity = await transcripts.activity(for: session)
      guard generation == self.generation else { return }
      let edited = Set((activity?.editedPaths ?? []).map(CanonicalPath.of))
      if edited != editedPaths {
        editedPaths = edited
        publishAll()
      }
    }
    if branchesMoved || transcriptGrew {
      continuation.yield(.branchReportOutdated(session.id))
    }
  }

  private func route(
    _ path: String, dirty: inout Set<String>, branchesMoved: inout Bool, transcriptGrew: inout Bool
  ) {
    guard let match = targets.first(where: { path == $0.prefix || path.hasPrefix($0.prefix + "/") })
    else { return }
    let relative = path == match.prefix ? "" : String(path.dropFirst(match.prefix.count + 1))

    switch match.target {
    case .root(let root):
      // Git's own folder is watched as such, and filtered there.
      if relative == ".git" || relative.hasPrefix(".git/") { return }
      dirty.insert(root)
    case .gitDirectory(let root, let sharesCommonDirectory, let sharers):
      // Objects are written by every commit and fetch, and say nothing a reference does not.
      if relative.hasPrefix("objects/") || relative == "objects" { return }
      // Another worktree's state, in the clone's own folder: not this repository's business.
      if sharesCommonDirectory, relative.hasPrefix("worktrees/") { return }
      if Self.isReference(relative) {
        branchesMoved = true
        // A shared reference moved: the worktrees of this clone may be ahead or behind now too.
        dirty.formUnion(sharers)
      } else if relative == "HEAD" {
        branchesMoved = true
      }
      dirty.insert(root)
    case .commonDirectory(let roots):
      guard Self.isReference(relative) else { return }
      branchesMoved = true
      dirty.formUnion(roots)
    case .transcript:
      // The folder holds the transcripts of every session opened in the same place: only this
      // session's own files say anything about it.
      guard transcriptIdentifiers.contains(where: { path.contains($0) }) else { return }
      transcriptGrew = true
    }
  }

  /// An event path spelled the way `CanonicalPath` spells the folders it is compared with.
  ///
  /// FSEvents reports the real path — `/private/var/folders/…` for a temporary folder — while
  /// Foundation, resolving links, drops `/private` from the few folders macOS links there. Asking
  /// the disk for each of thousands of event paths would cost more than the reading they trigger.
  static func comparable(_ path: String) -> String {
    for folder in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(folder) {
      return String(path.dropFirst("/private".count))
    }
    return path
  }

  /// The identifiers the session's transcript files are named after: one per conversation it has
  /// had, so that the files of an agent it was switched away from still count as its own.
  private var transcriptIdentifiers: [String] {
    (session?.conversations ?? []).compactMap { conversation in
      guard
        let identifier = conversation.resumeIdentifier?.trimmingCharacters(
          in: .whitespacesAndNewlines), !identifier.isEmpty
      else { return nil }
      return identifier
    }
  }

  private static func isReference(_ relative: String) -> Bool {
    relative.hasPrefix("refs/") || relative.hasPrefix("logs/refs/") || relative == "refs"
      || relative.hasPrefix("packed-refs")
  }
}

extension RepositoryStatusState {
  func with(phase: Phase) -> RepositoryStatusState {
    RepositoryStatusState(
      key: key, lastValid: lastValid, entries: entries, phase: phase, sharedWith: sharedWith)
  }
}

extension RepositoryStatusState.Phase {
  /// The same failure keeps the moment it started: a lock held for two minutes is said as such,
  /// and a state that did not change is not published again.
  func keepingSince(_ issue: RepositoryStatusIssue, now: Date) -> Self {
    if case .failed(let current, let since) = self {
      if current == issue { return .failed(current, since: since) }
      // A timeout carries the time it measured, a little different each time: still the same one.
      if case .timedOut = current, case .timedOut = issue { return .failed(current, since: since) }
    }
    return .failed(issue, since: now)
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
