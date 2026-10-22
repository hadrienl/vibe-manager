import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The automatic archive's rules, as the Settings show them and the application runs them (#405).
///
/// Held by the application's model: rules run whether Settings is open or not. Running a rule —
/// reading the sessions, archiving — is the application model's (`AppModel+ArchiveRules`); this
/// keeps the rules, their state and when they next need looking at.
@MainActor
@Observable
public final class ArchiveRulesModel {
  /// What the screen says went wrong.
  public enum Problem: Equatable, Sendable {
    /// `archive-rules.json` could not be read: written by a later version, or damaged. Nothing
    /// runs, and nothing is written over it.
    case unreadable
    case writing
  }

  /// One rule, as its line in the Settings says it.
  public struct Line: Identifiable, Equatable {
    public let stored: StoredArchiveRule
    public var id: UUID { stored.id }
    /// `nil` for a rule that does not read any more.
    public let explanation: String?
    public let shortSchedule: String?
    public let next: Date?
    /// How many sessions it would archive if it ran now.
    public let wouldArchive: Int
  }

  public private(set) var set = ArchiveRuleSet()
  public private(set) var loaded = false
  public var problem: Problem?

  @ObservationIgnored let store: any ArchiveRuleStore
  @ObservationIgnored let generators: any ArchiveRuleGeneratorResolving
  @ObservationIgnored let gitReader: (any RepositoryStatusReading)?
  @ObservationIgnored let diagnostics: Diagnostics
  @ObservationIgnored public var now: @MainActor () -> Date
  @ObservationIgnored public var calendar: @MainActor () -> Calendar
  /// Says a change to VoiceOver; replaced in tests.
  @ObservationIgnored public var announce: @MainActor (String) -> Void = { Announcer.announce($0) }
  /// The sessions as the rules see them, given by the application's model.
  @ObservationIgnored var candidates: @MainActor () -> [ArchiveCandidate] = { [] }
  /// The names of colours, symbols and agents, given by the application's model.
  @ObservationIgnored var vocabulary: @MainActor () -> ArchiveRuleVocabulary = {
    ArchiveRuleVocabulary()
  }
  @ObservationIgnored var ticker: Task<Void, Never>?
  @ObservationIgnored var wakeObserver: NSObjectProtocol?
  /// A run under way: another tick waits for the next one rather than running the same rules.
  @ObservationIgnored var isRunning = false
  /// Off in tests, which tick by hand.
  @ObservationIgnored public var startsTicker = true

  public init(
    store: any ArchiveRuleStore = InMemoryArchiveRuleStore(),
    generators: any ArchiveRuleGeneratorResolving = NoArchiveRuleGenerators(),
    gitReader: (any RepositoryStatusReading)? = nil,
    diagnostics: Diagnostics = .disabled,
    now: @escaping @MainActor () -> Date = Date.init,
    calendar: @escaping @MainActor () -> Calendar = { .autoupdatingCurrent }
  ) {
    self.store = store
    self.generators = generators
    self.gitReader = gitReader
    self.diagnostics = diagnostics
    self.now = now
    self.calendar = calendar
  }

  // MARK: Reading

  public func load() async {
    do {
      set = try await store.load()
      problem = nil
    } catch {
      problem = .unreadable
      diagnostics.record(.store, .error, "archive.rules.unreadable")
    }
    loaded = true
  }

  /// The explanation of rules and protections, in the application's language.
  public var explanation: ArchiveRuleExplanation {
    ArchiveRuleExplanation(vocabulary: vocabulary(), calendar: calendar(), locale: .current)
  }

  public var lines: [Line] {
    let explanation = self.explanation
    let now = now()
    let calendar = calendar()
    let candidates = candidates()
    let protections = set.readableProtections
    return set.rules.map { stored in
      guard let rule = stored.rule else {
        return Line(
          stored: stored, explanation: nil, shortSchedule: nil, next: nil, wouldArchive: 0)
      }
      let next: Date? =
        stored.runs
        ? ArchiveRuleScheduler.nextWake(
          for: ArchiveRuleSet(rules: [stored]), after: now, calendar: calendar)
        : nil
      let plan = protections.map {
        ArchiveRuleEvaluation.plan(
          rule: rule, protections: $0, candidates: candidates, now: now, calendar: calendar)
      }
      return Line(
        stored: stored, explanation: explanation.sentence(of: rule),
        shortSchedule: explanation.shortSchedule(rule.schedule),
        next: rule.schedule == .continuously ? nil : next,
        wouldArchive: plan?.archived.count ?? 0)
    }
  }

  /// Each protection's explanation; `nil` for one that does not read any more.
  public var protectionLines: [(stored: StoredArchiveProtection, explanation: String?)] {
    let explanation = self.explanation
    return set.protections.map { stored in
      (stored, stored.protection.map(explanation.sentence(of:)))
    }
  }

  /// Whether a rule that runs looks at every change of the sessions.
  var runsContinuously: Bool {
    self.set.rules.contains { $0.runs && $0.rule?.schedule == .continuously }
  }

  // MARK: Changing

  @discardableResult
  func change(_ body: @escaping @Sendable (inout ArchiveRuleSet) throws -> Void) async -> Bool {
    guard problem != .unreadable else { return false }
    do {
      set = try await store.update(body)
      problem = nil
      return true
    } catch {
      problem = .writing
      return false
    }
  }

  /// Turns a rule on, puts it on trial, or pauses it. Turning it on counts from now: what it
  /// missed while paused is not caught up.
  public func setState(_ state: StoredArchiveRule.State, of id: UUID) async {
    let now = now().rounded
    await change { set in
      guard let index = set.rules.firstIndex(where: { $0.id == id }) else { return }
      if set.rules[index].state == .paused, state != .paused {
        set.rules[index].activatedAt = now
      }
      set.rules[index].state = state
    }
    restartTicker()
  }

  public func remove(rule id: UUID) async {
    await change { set in set.rules.removeAll { $0.id == id } }
    restartTicker()
  }

  public func remove(protection id: UUID) async {
    await change { set in set.protections.removeAll { $0.id == id } }
  }

  public func setNotifies(_ notifies: Bool) async {
    await change { set in set.notifies = notifies }
  }

  /// Keeps what a sheet made: its rules, in `state`, and its protections. A rule refined from an
  /// existing one takes its place, under the same identifier.
  public func save(
    _ document: ArchiveRuleDocument, sentence: String, agent: String,
    state: StoredArchiveRule.State, replacing: UUID? = nil
  ) async -> Bool {
    let now = now().rounded
    let rules = document.rules.map { rule in
      StoredArchiveRule(
        text: ArchiveRulePrinter.text(of: rule), state: state, sentence: sentence, agent: agent,
        createdAt: now, activatedAt: now)
    }
    let protections = document.protections.map {
      StoredArchiveProtection(text: ArchiveRulePrinter.text(of: $0), sentence: sentence)
    }
    let saved = await change { set in
      var rules = rules
      if let replacing, let index = set.rules.firstIndex(where: { $0.id == replacing }),
        let first = rules.first
      {
        rules[0] = StoredArchiveRule(
          id: replacing, text: first.text, state: first.state, sentence: first.sentence,
          agent: first.agent, createdAt: set.rules[index].createdAt, activatedAt: now)
        set.rules[index] = rules.removeFirst()
      }
      // A name already taken by another rule is the new rule's: the old one goes.
      let names = Set(rules.compactMap { $0.rule?.name.lowercased() })
      set.rules.removeAll { $0.id != replacing && names.contains($0.rule?.name.lowercased() ?? "") }
      set.rules.append(contentsOf: rules)
      let known = Set(set.protections.map(\.text))
      set.protections.append(contentsOf: protections.filter { !known.contains($0.text) })
    }
    restartTicker()
    return saved
  }

  // MARK: The ticker

  /// What `AppModel` runs at each tick.
  @ObservationIgnored var tick: (@MainActor () async -> Void)?

  /// Wakes for the next time a rule is due, a quarter of an hour at most later — a clock or a
  /// time zone that changed is noticed —, and when the Mac wakes.
  func restartTicker() {
    ticker?.cancel()
    ticker = nil
    guard startsTicker, set.rules.contains(where: \.runs) else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.tick?()
        let now = self.now()
        let next = ArchiveRuleScheduler.nextWake(for: self.set, after: now, calendar: self.calendar())
        let delay = min(max(next?.timeIntervalSince(now) ?? 900, 1), 900)
        try? await Task.sleep(for: .seconds(delay))
      }
    }
    if wakeObserver == nil {
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.tick?() }
      }
    }
  }

  func stop() {
    ticker?.cancel()
    ticker = nil
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
  }

  func replace(_ set: ArchiveRuleSet) {
    self.set = set
  }
}

/// No agent: a workspace assembled without the composition.
public struct NoArchiveRuleGenerators: ArchiveRuleGeneratorResolving {
  public init() {
    // Nothing to set.
  }

  public func options() async -> [ArchiveRuleGeneratorOption] { [] }
}

extension Date {
  /// Whole seconds: what the rules' file keeps of a date.
  var rounded: Date {
    Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down))
  }
}
