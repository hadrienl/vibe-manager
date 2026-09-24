import Foundation
import VibeDomain

/// The sessions to put back to work, in the order to do it in.
public struct SessionRestoreIntent: Equatable, Sendable {
  public let sessionIDs: [SessionID]
  /// When the application stopped, as far as anything knows. `nil` after a clean quit, where the
  /// closing dates on the sessions themselves say it better.
  public let interruptedAt: Date?

  public init(sessionIDs: [SessionID], interruptedAt: Date? = nil) {
    self.sessionIDs = sessionIDs
    self.interruptedAt = interruptedAt
  }

  public var isEmpty: Bool { sessionIDs.isEmpty }
}

/// How the previous run of the application ended, and what it left to do.
public enum PreviousShutdown: Equatable, Sendable {
  /// Nothing to honour: a first launch, or a user who closed everything before quitting.
  case nothingToDo
  /// The application was quit with sessions running, and said so. They are resumed.
  case clean(SessionRestoreIntent)
  /// The application stopped without saying goodbye. The sessions are **offered**, not resumed:
  /// a crash is not an intention, and the agent that was running may be what brought the
  /// application down.
  case unexpected(SessionRestoreIntent, leftovers: [SessionRuntimeRecord])
  /// Another copy of the application holds these sessions. Nothing is reconciled and nothing is
  /// resumed: they are not ours to take.
  case otherInstance(processIdentifier: Int32)
  /// The application was quit with its agents left running, and the terminal host still holds
  /// them. Nothing is relaunched and nothing is sent to an agent: they are taken back as they are.
  case detached(DetachedSessions)
  /// The application was quit with its agents left running, and their host is alive and ours,
  /// but would not serve this copy: another copy is attached, or it did not answer in time. Nothing
  /// is reconciled, killed or claimed, so that trying again finds everything as it was.
  case hostUnavailable(reason: String)
}

/// What a quit that left the agents running finds at the next launch.
public struct DetachedSessions: Equatable, Sendable {
  /// Still running in the host, and still `active` in the store: to be attached to, as they are.
  public let running: [SessionID]
  /// Ended while the application was closed. Closed in the store, dated from when the host saw
  /// them end, and their last output is there to read.
  public let ended: [SessionID]
  /// What the quit had to stop rather than leave running, and what the host lost: resumed the
  /// way a clean quit resumes its own.
  public let resume: SessionRestoreIntent

  public init(running: [SessionID], ended: [SessionID], resume: SessionRestoreIntent) {
    self.running = running
    self.ended = ended
    self.resume = resume
  }
}

/// Reads what the previous run left behind, makes the store honest again, and consumes the
/// intention to resume.
///
/// Two gestures, and the whole of this ticket rests on them:
///
/// 1. every session the store still calls `active` is closed, because nothing can be running —
///    the application is the only thing that runs these processes and it has just started;
/// 2. the runtime document is taken over for this instance, which consumes the intention exactly
///    once.
///
/// After that, resuming a session is no longer a special case: it is `RestartSession` on a closed
/// session, with none of its rules rewritten.
public struct DetectPreviousShutdown: Sendable {
  private let repository: any SessionRepository
  private let recorder: SessionRuntimeRecorder
  private let processes: any ProcessLivenessProbe
  private let clock: any SessionClock
  private let processIdentifier: Int32
  private let host: (any TerminalHosting)?

  public init(
    repository: any SessionRepository,
    recorder: SessionRuntimeRecorder,
    processes: any ProcessLivenessProbe = SystemProcessLivenessProbe(),
    clock: any SessionClock = SystemSessionClock(),
    processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
    host: (any TerminalHosting)? = nil
  ) {
    self.repository = repository
    self.recorder = recorder
    self.processes = processes
    self.clock = clock
    self.processIdentifier = processIdentifier
    self.host = host
  }

  public func callAsFunction() async -> PreviousShutdown {
    var previous = await recorder.peek()

    // Asked of the host before anything else is decided: a session it still runs is the one
    // thing in the store that `active` is true of, and the reconciliation below must not close it.
    if let detached = previous, detached.phase == .detached {
      switch await host?.reconnect() ?? .absent {
      case .connected(_, let hosted):
        return await reattach(detached, hosted: hosted)
      case .absent:
        let stoppedOnPurpose = await hostWasStopped(since: detached)
        previous = Self.hostLost(
          detached, intended: stoppedOnPurpose || restartedSince(detached))
      case .unavailable(let reason):
        // Ours, alive, and holding the agents the user chose to keep: nothing about them can be
        // decided from here, so nothing is. Like a second copy of the application, this one
        // touches neither the store nor the document until it is asked to try again.
        await recorder.seal()
        return .hostUnavailable(reason: reason)
      case .refused:
        // A host that will not prove it is ours cannot be asked to stop anything, and its agents
        // are working in the folders the sessions are about to be resumed in. It is killed the
        // way a leftover is — only once its identity is confirmed — its agents' groups with it,
        // and what it ran is offered.
        if let identity = detached.host,
          processes.identify(
            processGroup: identity.processIdentifier, startedAt: identity.processStartedAt)
            == .matches
        {
          processes.terminate(processGroup: identity.processIdentifier)
        }
        previous = Self.hostLost(detached, intended: false)
      }
    }

    // A document that says `running` is only about a living copy of the application if the pid it
    // names is still *that* process. Confronted with nothing but the number, a pid recycled by any
    // long-lived program would read as a second copy for ever — the store would never be
    // reconciled and nothing would ever be restored again — and one that happened to equal ours
    // would make a crashed run look like this very launch.
    if let previous, previous.phase == .running, let instance = livingInstance(previous) {
      // Our own claim, read back: this launch has already been detected. Asked a second time it
      // answers nothing rather than reconciling again, because the sessions that are active by
      // then are the ones this instance has just started.
      guard instance != processIdentifier else { return .nothingToDo }
      // Nothing is claimed, and nothing will be: from here on this instance only reads the
      // document. Writing it at the first session started would overwrite the other copy's pid
      // and process groups, and its own next launch would find neither.
      await recorder.seal()
      return .otherInstance(processIdentifier: instance)
    }

    // Leftovers are dealt with before the document is claimed, and that order is not incidental:
    // the sessions survive a crash in the store, while the process groups survive nowhere else.
    // Claiming first and crashing a moment later would lose their identity for good, and an
    // unidentifiable group is one nothing may signal.
    let leftovers = leftovers(of: previous)
    await recorder.claim()

    // Read before anything is written, because reconciling closes these sessions and writes a
    // new `updatedAt` on every one of them: asked afterwards, the store could no longer say which
    // one the user was working in.
    let stored = (try? await repository.sessions()) ?? []
    let lastWorkedAt = Dictionary(
      stored.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })

    let reconciled = await reconcileStaleSessions(
      Self.mostRecentlyWorkedFirst(stored.filter { $0.status == .active }),
      lastSeenAt: previous?.lastSeenAt
    )
    let recorded = previous?.sessions.map(\.sessionID) ?? []
    let ids = await restorable(recorded + reconciled.filter { !recorded.contains($0) })

    // A stopped document with nothing to resume, or no document at all and a store with nothing
    // stale in it. Either way there is nothing to say.
    guard !ids.isEmpty else { return .nothingToDo }

    switch previous?.phase {
    // `detached` never gets this far: it was reattached, or rewritten as what losing its host
    // amounts to. It is grouped with the one phase that asks nothing, for the compiler's sake.
    case .stopped, .detached:
      // The order a clean quit wrote is already the order to come back in: it closed its sessions
      // most recently worked first.
      return .clean(SessionRestoreIntent(sessionIDs: ids))
    case .running, .none:
      // A crash wrote nothing in any particular order — the records are in the order the sessions
      // were *started*, which is not the order they were worked in.
      let ordered = ids.sorted { lhs, rhs in
        let left = lastWorkedAt[lhs] ?? .distantPast
        let right = lastWorkedAt[rhs] ?? .distantPast
        return left == right ? lhs.description < rhs.description : left > right
      }
      return .unexpected(
        SessionRestoreIntent(sessionIDs: ordered, interruptedAt: previous?.lastSeenAt),
        leftovers: leftovers
      )
    }
  }

  /// The pid of the instance that wrote this document, when that instance is still running.
  ///
  /// `unknown` — something answers to the pid but nothing says what it is — is treated as a living
  /// instance. It is the conservative half of the two mistakes: taking a document from a copy that
  /// is working in these sessions would close its sessions under its own agents, while refusing to
  /// take one says so in a banner the user can act on.
  private func livingInstance(_ state: SessionRuntimeState) -> Int32? {
    switch processes.identify(
      processGroup: state.processIdentifier, startedAt: state.processStartedAt)
    {
    case .matches, .unknown: return state.processIdentifier
    case .differs, .gone: return nil
    }
  }

  /// Closes the sessions the store still calls active, and answers which they were.
  ///
  /// The closing date is the last instant the previous run is known to have been alive, not now:
  /// "closed at 18:40" is about the evening the user remembers, while the moment they reopened
  /// the application says nothing about when their work stopped.
  private func reconcileStaleSessions(
    _ stale: [WorkSession],
    lastSeenAt: Date?
  ) async -> [SessionID] {
    guard !stale.isEmpty else { return [] }

    let fallback = clock.now()
    var closed: [SessionID] = []
    for session in stale {
      let date = max(lastSeenAt ?? fallback, session.updatedAt)
      let updated = try? await repository.mutate(id: session.id) { session in
        guard session.status == .active else { return }
        try session.close(at: date)
      }
      guard let updated, updated.status == .closed else { continue }
      closed.append(updated.id)
    }
    return closed
  }

  private static func mostRecentlyWorkedFirst(_ sessions: [WorkSession]) -> [WorkSession] {
    sessions.sorted {
      $0.updatedAt == $1.updatedAt
        ? $0.id.description < $1.id.description : $0.updatedAt > $1.updatedAt
    }
  }

  /// Keeps only the identifiers that name something a restart could even be offered for.
  ///
  /// An archived session, or one deleted from the store by hand, has no business in a count the
  /// banner will read out loud: "3 sessions were running" must be three sessions the user can
  /// see. Everything subtler than that — an agent that is gone, a folder that moved — is left to
  /// `RestartSession`, which says it in a sentence.
  private func restorable(_ ids: [SessionID]) async -> [SessionID] {
    var result: [SessionID] = []
    for id in ids {
      guard let session = try? await repository.session(id: id), session.status == .closed else {
        continue
      }
      result.append(id)
    }
    return result
  }

  /// Whether the Mac has restarted since this document was written.
  private func restartedSince(_ state: SessionRuntimeState) -> Bool {
    guard let booted = processes.bootTime() else { return false }
    return booted > state.lastSeenAt
  }

  /// Whether the host said, on its way out, that it was told to stop after this document was
  /// written: a logout, a shutdown, a `kill`.
  private func hostWasStopped(since state: SessionRuntimeState) async -> Bool {
    guard let requested = await host?.lastStopRequest() else { return false }
    return requested >= state.lastSeenAt
  }

  /// A `detached` document whose host is gone, rewritten as what that loss amounts to.
  ///
  /// When the host was stopped on purpose — the Mac restarted, the user logged out, the host said
  /// it was told to stop — leaving the agents running was an intention to carry on that the system
  /// cut short: it reads as a clean quit, and the sessions are resumed. Otherwise the host crashed
  /// or was killed outright, which is a crash, and the sessions are offered — with their process
  /// groups, so that an agent that outlived its host is found before a second one is started in the
  /// same folder.
  private static func hostLost(
    _ state: SessionRuntimeState,
    intended: Bool
  ) -> SessionRuntimeState {
    var lost = state
    lost.phase = intended ? .stopped : .running
    lost.sessions = state.sessions + (state.resuming ?? [])
    lost.resuming = nil
    lost.host = nil
    return lost
  }

  /// Takes back what the host still holds, and settles the rest.
  private func reattach(
    _ previous: SessionRuntimeState,
    hosted: [HostedSessionSummary]
  ) async -> PreviousShutdown {
    let byID = Dictionary(hosted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // Only a session the host lost can have left a process nobody holds.
    // Identified, they are stopped here, as after a crash; one that cannot be identified is left
    // alone, and a reattach has no offer on screen to carry that warning.
    _ = leftovers(of: previous.sessions.filter { byID[$0.sessionID] == nil })
    await recorder.claim()

    let stored = (try? await repository.sessions()) ?? []
    let storedByID = Dictionary(
      stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let active = Self.mostRecentlyWorkedFirst(stored.filter { $0.status == .active })

    var running: [SessionID] = []
    var ended: [SessionID] = []
    var stale: [WorkSession] = []
    for session in active {
      guard let summary = byID[session.id] else {
        stale.append(session)
        continue
      }
      if !summary.state.isFinished {
        running.append(session.id)
      } else if await close(session, at: summary.endedAt ?? previous.lastSeenAt) {
        ended.append(session.id)
      }
    }
    // What the host holds for a session the store no longer calls active — archived, deleted by
    // hand, closed by a copy that could not reach the host — has nobody left to show it to.
    for summary in hosted where storedByID[summary.id]?.status != .active {
      await host?.discard(summary.id)
    }

    let reconciled = await reconcileStaleSessions(stale, lastSeenAt: previous.lastSeenAt)
    let queued = (previous.resuming ?? []).map(\.sessionID)
    let resume = await restorable(queued + reconciled.filter { !queued.contains($0) })
    return .detached(
      DetachedSessions(
        running: running,
        ended: ended,
        resume: SessionRestoreIntent(sessionIDs: resume)
      )
    )
  }

  private func close(_ session: WorkSession, at date: Date) async -> Bool {
    let updated = try? await repository.mutate(id: session.id) { session in
      guard session.status == .active else { return }
      try session.close(at: max(date, session.updatedAt))
    }
    return updated?.status == .closed
  }

  /// Process groups from the previous run that are still alive.
  ///
  /// A group whose identity is confirmed is stopped here and now: an agent that survived the
  /// application holds the worktree the session is about to be restarted in. A group that answers
  /// but cannot be identified is **reported and left alone** — pids are recycled, and tidying up
  /// on the strength of a number would kill somebody else's program.
  private func leftovers(of previous: SessionRuntimeState?) -> [SessionRuntimeRecord] {
    leftovers(of: previous?.sessions ?? [])
  }

  private func leftovers(of records: [SessionRuntimeRecord]) -> [SessionRuntimeRecord] {
    var reported: [SessionRuntimeRecord] = []
    for record in records {
      guard let group = record.processGroup else { continue }
      switch processes.identify(processGroup: group, startedAt: record.processStartedAt) {
      case .matches:
        processes.terminate(processGroup: group)
      case .unknown:
        reported.append(record)
      case .differs, .gone:
        continue
      }
    }
    return reported
  }
}
