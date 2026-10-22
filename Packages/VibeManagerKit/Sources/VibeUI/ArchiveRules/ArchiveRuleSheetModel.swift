import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The sheet where rules are described in a sentence, translated by an agent, explained, tried
/// on the real sessions, refined, and kept (#405). Nothing it shows is written until it is saved.
@MainActor
@Observable
public final class ArchiveRuleSheetModel: Identifiable {
  public enum Purpose: Equatable, Sendable {
    case newRules
    /// Redo or refine a rule kept: its version replaces it.
    case refine(StoredArchiveRule)
    case protection
  }

  /// One translation, kept until the sheet closes: the sheet can go back to it.
  public struct Version: Identifiable, Equatable {
    public let id = UUID()
    public let sentence: String
    public let agentName: String
    public let agentID: String
    public let document: ArchiveRuleDocument
    public let text: String
    public let assumptions: [ArchiveRuleAssumption]
  }

  public enum Problem: Equatable {
    case generation(ArchiveRuleGenerationError)
    case noAgent
    case saving
  }

  /// A session of the preview: what the rules would do with it, from now.
  public struct PreviewRow: Identifiable, Equatable {
    public let session: WorkSession
    public let verdict: ArchiveVerdict
    /// The next time it would be archived, and by which rule.
    public let when: Date?
    public let ruleName: String?
    public var id: SessionID { session.id }
  }

  public let id = UUID()
  public let purpose: Purpose
  public var sentence: String
  public var refinement = ""
  public private(set) var options: [ArchiveRuleGeneratorOption] = []
  public private(set) var optionsLoaded = false
  public var selectedAgent: AgentProviderID?
  public private(set) var versions: [Version] = []
  public private(set) var question: ArchiveRuleQuestion?
  public var chosenAnswer: String?
  public private(set) var generatingAgent: String?
  public private(set) var isRetrying = false
  public var problem: Problem?
  /// The sentence a question was asked about, and the answers given so far.
  private var askedSentence: String?
  private var answers: [ArchiveRuleGenerationRequest.Answer] = []
  @ObservationIgnored private var run: Task<Void, Never>?

  @ObservationIgnored let rules: ArchiveRulesModel
  @ObservationIgnored let context: @MainActor () -> ArchiveRuleContext
  @ObservationIgnored public var announce: @MainActor (String) -> Void = { Announcer.announce($0) }

  init(
    purpose: Purpose, rules: ArchiveRulesModel,
    context: @escaping @MainActor () -> ArchiveRuleContext
  ) {
    self.purpose = purpose
    self.rules = rules
    self.context = context
    if case .refine(let stored) = purpose {
      sentence = stored.sentence
      selectedAgent = AgentProviderID(stored.agent)
    } else {
      sentence = ""
    }
  }

  public var current: Version? { versions.last }
  public var isGenerating: Bool { generatingAgent != nil }

  public func loadOptions() async {
    options = await rules.generators.options()
    optionsLoaded = true
    if selectedAgent == nil || !options.contains(where: { $0.id == selectedAgent }) {
      selectedAgent = options.first?.id
    }
  }

  // MARK: Translating

  /// The first translation, or a new one of the sentence edited.
  public func translate() {
    let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    versions.removeAll()
    answers.removeAll()
    askedSentence = nil
    question = nil
    generate(text, refining: nil)
  }

  /// A new version from the current one: “rather Friday at noon”.
  public func refine() {
    let text = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let current else { return }
    answers.removeAll()
    askedSentence = nil
    question = nil
    generate(text, refining: current)
  }

  /// Answers the agent's question: the sentence goes again, with the answer.
  public func answer(_ choice: String) {
    guard let question, let asked = askedSentence else { return }
    answers.append(.init(question: question.text, answer: choice))
    self.question = nil
    chosenAnswer = nil
    generate(asked, refining: askedRefining)
  }

  @ObservationIgnored private var askedRefining: Version?

  private func generate(_ text: String, refining: Version?) {
    guard let option = options.first(where: { $0.id == selectedAgent }) ?? options.first else {
      problem = .noAgent
      return
    }
    problem = nil
    isRetrying = false
    generatingAgent = option.descriptor.displayName
    announce(
      String(
        localized: "\(option.descriptor.displayName) is translating the sentence.",
        bundle: .module, comment: "Said to VoiceOver. The argument is an agent's name."))
    let earlier = versions.map(\.sentence)
    let request = ArchiveRuleGenerationRequest(
      sentence: text, context: context(), current: refining?.text,
      earlierRequests: refining == nil ? [] : earlier, answers: answers)
    let attempts = AttemptCounter()
    let started = ContinuousClock.now
    let generator = GenerateArchiveRules(generator: option.generator)
    run?.cancel()
    run = Task { [weak self] in
      let outcome: Result<ArchiveRuleAnswer, Error>
      do {
        outcome = .success(
          try await generator(request) { event in
            switch event {
            case .attempt(let number):
              attempts.set(number)
              if number == 2 { Task { @MainActor in self?.hearRetry() } }
            case .rejected: break
            }
          })
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled else { return }
      self?.finish(
        outcome, sentence: text, refining: refining, option: option, attempts: attempts.value,
        duration: ContinuousClock.now - started)
    }
  }

  private func hearRetry() {
    isRetrying = true
  }

  private func finish(
    _ outcome: Result<ArchiveRuleAnswer, Error>, sentence: String, refining: Version?,
    option: ArchiveRuleGeneratorOption, attempts: Int, duration: Duration
  ) {
    generatingAgent = nil
    isRetrying = false
    let token: GenerationOutcome
    switch outcome {
    case .success(.rules(let document, let text, let assumptions)):
      token = .rules
      versions.append(
        Version(
          sentence: sentence, agentName: option.descriptor.displayName,
          agentID: option.id.rawValue, document: document, text: text, assumptions: assumptions))
      refinement = ""
      announce(
        String(
          localized: "Version \(versions.count) is ready.", bundle: .module,
          comment: "Said to VoiceOver once an agent translated a sentence into archive rules."))
    case .success(.question(let question)):
      token = .question
      self.question = question
      askedSentence = sentence
      askedRefining = refining
      announce(question.text)
    case .failure(let error):
      let failure = (error as? ArchiveRuleGenerationError) ?? .failed("unknown")
      switch failure {
      case .invalid: token = .invalid
      case .timedOut: token = .timedOut
      case .unavailable: token = .unavailable
      case .failed: token = .failed
      }
      problem = .generation(failure)
      announce(message(of: .generation(failure)))
    }
    // How it went, never what was asked or answered.
    rules.diagnostics.record(
      .session, .info, "archive.rules.generation",
      [
        "outcome": .token(token.diagnosticToken), "attempts": .count(attempts),
        "duration": .duration(duration), "sentenceLength": .count(sentence.count),
      ])
  }

  public func cancel() {
    run?.cancel()
    run = nil
    generatingAgent = nil
    isRetrying = false
    announce(
      String(
        localized: "The translation was cancelled.", bundle: .module,
        comment: "Said to VoiceOver."))
  }

  /// Back to the version before the last one, its sentence in the field to refine again.
  public func back() {
    guard let last = versions.popLast() else { return }
    refinement = last.sentence
  }

  public func goBack(to version: Version) {
    guard let index = versions.firstIndex(of: version) else { return }
    versions.removeSubrange((index + 1)...)
  }

  /// Keeps the current version: turned on, or on trial.
  @discardableResult
  public func save(trial: Bool) async -> Bool {
    guard let current else { return false }
    let replacing: UUID? = if case .refine(let stored) = purpose { stored.id } else { nil }
    // A protection sheet keeps protections only: nothing it saves archives anything.
    let document =
      purpose == .protection
      ? ArchiveRuleDocument(protections: current.document.protections) : current.document
    guard !document.isEmpty else { return false }
    let saved = await rules.save(
      document, sentence: versions.first?.sentence ?? current.sentence,
      agent: current.agentID, state: trial ? .trial : .active, replacing: replacing)
    if saved {
      announce(
        trial
          ? String(
            localized: "The rules are on trial: they archive nothing yet.", bundle: .module,
            comment: "Said to VoiceOver.")
          : String(
            localized: "The rules are on.", bundle: .module, comment: "Said to VoiceOver."))
    } else {
      problem = .saving
    }
    return saved
  }

  // MARK: What the screen says

  public func message(of problem: Problem) -> String {
    switch problem {
    case .noAgent:
      String(
        localized: "No agent can translate a sentence now.", bundle: .module,
        comment: "The sheet of a new archive rule: Claude Code and Codex are missing or signed out.")
    case .saving:
      String(
        localized: "The rules could not be saved.", bundle: .module,
        comment: "The sheet of a new archive rule.")
    case .generation(.invalid):
      String(
        localized: "The sentence could not be translated into rules. Try saying it another way.",
        bundle: .module, comment: "The sheet of a new archive rule: the agent's answers were unusable.")
    case .generation(.timedOut):
      String(
        localized: "The agent took too long to answer.", bundle: .module,
        comment: "The sheet of a new archive rule.")
    case .generation(.unavailable(.signedOut)):
      String(
        localized: "The agent is signed out.", bundle: .module,
        comment: "The sheet of a new archive rule.")
    case .generation(.unavailable(.outdated)):
      String(
        localized: "The agent is too old to answer a schema; update it.", bundle: .module,
        comment: "The sheet of a new archive rule.")
    case .generation:
      String(
        localized: "The agent could not translate the sentence.", bundle: .module,
        comment: "The sheet of a new archive rule.")
    }
  }

  /// What the current version would do with the real sessions, from now: the sessions it would
  /// archive and when, the ones it would skip or protects.
  public var preview: [PreviewRow] {
    guard let current else { return [] }
    let now = rules.now()
    let calendar = rules.calendar()
    let candidates = rules.candidates()
    let protections = current.document.protections + (rules.set.readableProtections ?? [])
    var rows: [PreviewRow] = []
    for candidate in candidates where candidate.session.taskStatus == .done {
      var best: PreviewRow?
      for rule in current.document.rules {
        let verdict = ArchiveRuleEvaluation.verdict(
          of: candidate, rule: rule, protections: protections, now: now, calendar: calendar)
        switch verdict {
        case .archive:
          let when = ArchiveRuleScheduler.nextWake(
            for: ArchiveRuleSet(rules: [
              StoredArchiveRule(
                text: ArchiveRulePrinter.text(of: rule), state: .active, sentence: "", agent: "",
                createdAt: now, activatedAt: now)
            ]), after: now, calendar: calendar)
          if best?.verdict != .archive || (when ?? .distantFuture) < (best?.when ?? .distantFuture)
          {
            best = PreviewRow(
              session: candidate.session, verdict: verdict, when: when, ruleName: rule.name)
          }
        case .protected, .running, .unarchived:
          if best == nil {
            best = PreviewRow(
              session: candidate.session, verdict: verdict, when: nil, ruleName: rule.name)
          }
        default:
          continue
        }
      }
      if let best { rows.append(best) }
    }
    return rows.sorted {
      ($0.when ?? .distantFuture, $0.session.name) < ($1.when ?? .distantFuture, $1.session.name)
    }
  }

  /// The next times the current version's rules run.
  public var nextTimes: [Date] {
    guard let current else { return [] }
    let now = rules.now()
    let calendar = rules.calendar()
    let horizon = calendar.date(byAdding: .month, value: 2, to: now) ?? now
    return current.document.rules.flatMap {
      $0.schedule.occurrences(from: now, through: horizon, calendar: calendar, activatedAt: now, limit: 4)
    }
    .sorted().prefix(4).map { $0 }
  }
}

/// How a translation ended, for the diagnostics.
private enum GenerationOutcome: String, DiagnosticTokenConvertible {
  case rules, question, invalid, timedOut, unavailable, failed
}

/// Counts the attempts of a translation, from the events of `GenerateArchiveRules`.
private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func set(_ number: Int) {
    lock.withLock { count = number }
  }
}
