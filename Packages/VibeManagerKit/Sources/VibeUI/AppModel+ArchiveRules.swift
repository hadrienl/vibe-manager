import Foundation
import VibeApplication
import VibeDomain

/// Running the automatic archive's rules (#405): the sessions as the rules see them, the times
/// due claimed, the sessions archived as the user would archive them — detached, then written.
/// ⌘Z does not take them back: they are unarchived from the archive.
extension AppModel {
  /// Reads the rules, and starts looking at them.
  func startArchiveRules() async {
    guard let archiveRules else { return }
    archiveRules.candidates = { [weak self] in self?.archiveCandidates() ?? [] }
    archiveRules.vocabulary = { [weak self] in self?.archiveVocabulary() ?? ArchiveRuleVocabulary()
    }
    archiveRules.readGitFacts = { [weak self] in await self?.withGitFacts($0) ?? $0 }
    archiveRules.tick = { [weak self] in await self?.runArchiveRules() }
    await archiveRules.load()
    archiveRules.restartTicker()
  }

  /// Opens the Settings on the automatic archive's tab: what the Done column's button asks.
  public func showArchiveRulesSettings() {
    settingsPage = .archiveRules
  }

  /// The sessions as the rules see them. Whether their folder has changes and which branch it is
  /// on are not known here: `withGitFacts` reads them when a rule asks.
  func archiveCandidates() -> [ArchiveCandidate] {
    sessions.filter { $0.status != .archived }.map { session in
      ArchiveCandidate(
        session: session, project: groupName(of: session),
        isRunning: launcher?.isRunning(session.id) == true
          || !runningDrawerCommands(of: session.id).isEmpty
          || archivingSessionIDs.contains(session.id))
    }
  }

  /// The name of a session's group, as the sidebar shows it.
  func groupName(of session: WorkSession) -> String? {
    guard let key = folderKey(for: session) else { return nil }
    return folderLabels[key] ?? URL(fileURLWithPath: key.path).lastPathComponent
  }

  /// The colours of the palette by their names, the symbols' names and the agents'.
  func archiveVocabulary() -> ArchiveRuleVocabulary {
    var colors: [String: String] = [:]
    for swatch in appearancePalette.offered.swatches {
      if let name = swatch.name ?? SessionAppearanceCatalog.colorName(of: swatch.hex) {
        colors[swatch.hex] = name
      }
    }
    var symbols: [String: String] = [:]
    for symbol in appearancePalette.offered.symbols {
      symbols[symbol] = String(localized: SessionSymbolName.label(for: symbol))
    }
    return ArchiveRuleVocabulary(colorNames: colors, symbolNames: symbols, agentNames: agentNames)
  }

  /// What the agent is told of the user's world (#405): never anything of a session but the
  /// names of the groups.
  func archiveRuleContext() -> ArchiveRuleContext {
    let calendar = archiveRules?.calendar() ?? .autoupdatingCurrent
    let vocabulary = archiveVocabulary()
    let groups = Set(sessions.compactMap(groupName(of:))).sorted()
    return ArchiveRuleContext(
      now: archiveRules?.now() ?? Date(), timeZone: calendar.timeZone,
      firstWeekday: calendar.firstWeekday,
      language: Locale.current.language.minimalIdentifier,
      palette: appearancePalette.offered.swatches.map {
        ArchiveRuleContext.Color(name: vocabulary.colorNames[$0.hex] ?? $0.hex, hex: $0.hex)
      },
      symbols: appearancePalette.offered.symbols, groups: groups,
      agents: agentNames.keys.sorted())
  }

  /// The candidates in Done, with the branch and the state of their folder read from Git.
  func withGitFacts(_ candidates: [ArchiveCandidate]) async -> [ArchiveCandidate] {
    guard let reader = archiveRules?.gitReader else { return candidates }
    let folders = Set(
      candidates.filter { $0.session.taskStatus == .done }.compactMap(\.folder))
    // Several folders at a time: one slow to answer does not hold up the others.
    let facts = await withTaskGroup(of: (String, String?, Bool)?.self) { group in
      var facts: [String: (branch: String?, isDirty: Bool)] = [:]
      var pending = folders.makeIterator()
      func read(_ folder: String) {
        group.addTask {
          guard case .success(let status) = await reader.status(atPath: folder, limit: 1) else {
            return nil
          }
          let counts = status.counts
          return (
            folder, status.branch.branchName,
            counts.staged + counts.unstaged + counts.untracked + counts.conflicted > 0
          )
        }
      }
      for _ in 0..<8 {
        guard let folder = pending.next() else { break }
        read(folder)
      }
      while let answer = await group.next() {
        if let (folder, branch, isDirty) = answer { facts[folder] = (branch, isDirty) }
        if let folder = pending.next() { read(folder) }
      }
      return facts
    }
    return candidates.map { candidate in
      guard candidate.session.taskStatus == .done, let folder = candidate.folder,
        let fact = facts[folder]
      else { return candidate }
      var candidate = candidate
      candidate.branch = fact.branch
      candidate.isDirty = fact.isDirty
      return candidate
    }
  }

  /// A change of the sessions, for the rules that run continuously: they run now, or at the end
  /// of the minute the last run used — a change within it is not left for the next quarter of
  /// an hour. The reloads of a run are its own, not changes to look at.
  func archiveRulesSawChange() {
    guard let rules = archiveRules, rules.runsContinuously, !rules.isRunning,
      rules.continuousRun == nil
    else { return }
    let last =
      rules.set.rules.filter { $0.runs && $0.rule?.schedule == .continuously }
      .compactMap(\.lastHandled).max() ?? .distantPast
    let wait = last.addingTimeInterval(ArchiveRuleScheduler.continuousThrottle)
      .timeIntervalSince(rules.now())
    rules.continuousRun = Task { [weak self] in
      if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
      rules.continuousRun = nil
      guard !Task.isCancelled else { return }
      await self?.runArchiveRules()
    }
  }

  /// One tick: the rules due now claimed, then run in the order of the list.
  func runArchiveRules() async {
    // A write of the Settings that failed does not stop the rules: only a file that cannot be
    // read does.
    guard let model = archiveRules, !model.isRunning, model.problem != .unreadable,
      case .loaded = state
    else { return }
    model.isRunning = true
    defer { model.isRunning = false }
    // A protection that no longer reads keeps every rule from running: what it was meant to
    // protect cannot be told. Nothing is claimed, so that the times due catch up once it reads.
    guard model.set.readableProtections != nil else {
      diagnostics.record(.store, .error, "archive.rules.protectionUnreadable")
      return
    }
    let calendar = model.calendar()
    let now = model.now()
    let scheduler = ArchiveRuleScheduler(
      store: model.store, clock: FixedArchiveClock(date: now), calendar: { calendar })
    let runs: [ArchiveDueRun]
    do {
      runs = try await scheduler.claimDueRuns()
      model.replace(try await model.store.load())
    } catch {
      diagnostics.record(.store, .error, "archive.rules.claimFailed")
      return
    }
    guard !runs.isEmpty else { return }
    // Read again with the claim: another copy may have changed them since.
    guard let protections = model.set.readableProtections else {
      diagnostics.record(.store, .error, "archive.rules.protectionUnreadable")
      return
    }
    var candidates = archiveCandidates()
    let conditions = runs.compactMap(\.rule.condition) + protections.map(\.condition)
    if conditions.contains(where: \.readsGit) {
      candidates = await withGitFacts(candidates)
    }
    var archivedAny = false
    for run in runs {
      let started = ContinuousClock.now
      let plan = ArchiveRuleEvaluation.plan(
        rule: run.rule, protections: protections, candidates: candidates, now: now,
        calendar: calendar)
      var archived: [SessionID] = []
      var photos: [ArchivedSessionSnapshot] = []
      if !run.isTrial, !plan.archived.isEmpty {
        // Reading Git and archiving take time: the user may have started, moved or protected a
        // session since the plan. Each is looked at again, as it stands now, right before.
        await reload()
        for id in plan.archived {
          guard var live = archiveCandidates().first(where: { $0.id == id }) else { continue }
          if let planned = candidates.first(where: { $0.id == id }) {
            live.branch = planned.branch
            live.isDirty = planned.isDirty
          }
          guard
            ArchiveRuleEvaluation.verdict(
              of: live, rule: run.rule, protections: protections, now: now, calendar: calendar)
              == .archive,
            archivingSessionIDs.insert(id).inserted
          else { continue }
          defer { archivingSessionIDs.remove(id) }
          // Photographed as it stands right before, for the batch's report (#408).
          let photo = await archiveSnapshot(of: live.session, at: now)
          if await archiveByRule(id, run: run) {
            archived.append(id)
            photos.append(photo)
          }
        }
        archivedAny = archivedAny || !archived.isEmpty
        let gone = Set(archived)
        candidates.removeAll { gone.contains($0.id) }
      }
      if run.isTrial {
        for id in plan.archived {
          guard let candidate = candidates.first(where: { $0.id == id }) else { continue }
          photos.append(await archiveSnapshot(of: candidate.session, at: now))
        }
      }
      let batch = await archiveReports?.recordRun(
        kind: run.isTrial
          ? .trial(id: run.ruleID, name: run.rule.name) : .rule(id: run.ruleID, name: run.rule.name),
        date: now, sessions: photos,
        skipped: plan.skipped.compactMap { id, verdict in
          guard let reason = SkippedSession.Reason(verdict),
            let name = candidates.first(where: { $0.id == id })?.session.name
          else { return nil }
          return SkippedSession(sessionID: id, name: name, reason: reason)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
      let count = run.isTrial ? plan.archived.count : archived.count
      let result = ArchiveRunResult(
        date: now, archived: count, skipped: plan.skipped.count, isTrial: run.isTrial)
      try? await scheduler.record(result, for: run.ruleID)
      diagnostics.record(
        .session, .info, "archive.rules.run",
        [
          "archived": .count(count), "skipped": .count(plan.skipped.count),
          "trial": .flag(run.isTrial), "catchUp": .flag(run.isCatchUp),
          "duration": .duration(ContinuousClock.now - started),
        ])
      if !run.isTrial, count > 0, model.set.notifies {
        requestNotifier?.postArchiveRun(ruleName: run.rule.name, count: count, batchID: batch?.id)
      }
    }
    if let set = try? await model.store.load() { model.replace(set) }
    if archivedAny {
      await reload()
      reconcileSelection()
    }
  }
}

extension AppModel {
  /// Archives one session for a rule, as an archive by hand does but without ⌘Z: a rule's archive
  /// is undone from the archive, never by a key the user pressed for something else. The session
  /// on screen hands the selection to its neighbour, the keyboard staying in the sidebar.
  func archiveByRule(_ id: SessionID, run: ArchiveDueRun) async -> Bool {
    let visible = orderedSessions
    let wasSelected = selectedSessionID == id
    do {
      let archival = try await archiveProcess(id, cause: .rule(id: run.ruleID, name: run.rule.name))
      // A process that could not be stopped is said, as after an archive by hand.
      report(archival.detachment, for: archival.session, action: .archived)
    } catch {
      diagnostics.record(
        .session, .error, "archive.rules.archiveFailed", ["session": diagnostics.pseudonym(id)])
      return false
    }
    prepareHandOff(from: id, listedBefore: visible)
    if wasSelected, layout.columns.isSidebarVisible {
      keyboardHeldInSidebarFor = preferredSelection
    }
    await reload()
    handOffSelection(from: id, listedBefore: visible, wasSelected: wasSelected)
    reconcileSelection()
    if wasSelected, selectedSessionID != id, layout.columns.isSidebarVisible {
      keyboardHeldInSidebarFor = selectedSessionID
      focusSidebar()
    }
    return true
  }
}

/// The time a tick runs at, the same for every rule of the tick.
private struct FixedArchiveClock: SessionClock {
  let date: Date
  func now() -> Date { date }
}

extension ArchiveCondition {
  /// Whether it reads the folder's branch or changes, which only Git knows.
  public var readsGit: Bool {
    switch self {
    case .test(let test): test.field == .gitBranch || test.field == .gitDirty
    case .not(let inner): inner.readsGit
    case .all(let parts), .any(let parts): parts.contains(where: \.readsGit)
    }
  }
}

extension SkippedSession.Reason {
  /// The reason a report keeps of a verdict that skipped a session; `nil` for one it does not.
  init?(_ verdict: ArchiveVerdict) {
    switch verdict {
    case .running: self = .running
    case .unarchived: self = .unarchived
    case .overLimit: self = .overLimit
    default: return nil
    }
  }
}
