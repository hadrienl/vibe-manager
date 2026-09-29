import Foundation
import Observation
import SwiftUI
import VibeApplication

/// The user's own themes (#118): the ones kept, and the one being made — described to an agent,
/// changed version after version, shown on trial in the preview and in every conversation, then
/// kept or dropped.
///
/// The trial never touches the settings: `appearance` only changes when a theme is saved. Dropping
/// the trial — folding the panel, choosing a card, leaving the tab — is emptying `versions`, and
/// the theme in force is back without anything to restore.
@MainActor
@Observable
public final class ConversationThemesModel {
  /// One version of the theme being made, and what asked for it.
  public struct Version: Identifiable, Sendable {
    public let id = UUID()
    public let request: String
    public let agentName: String
    public let theme: ConversationTheme
  }

  /// Why the last thing asked did not happen. The theme on screen is untouched.
  public enum Problem: Hashable, Sendable {
    case unavailable(agent: String, ThemeGenerationError.Unavailability)
    case timedOut(agent: String)
    case failed(agent: String)
    case invalid(agent: String)
    case couldNotSave
    case couldNotDelete
    case couldNotExport

    public var message: LocalizedStringResource {
      switch self {
      case .unavailable(let agent, .missing):
        LocalizedStringResource(
          "\(agent) can no longer be found. Check that it is installed, then try again.",
          bundle: .module)
      case .unavailable(let agent, .signedOut):
        LocalizedStringResource(
          "\(agent) is signed out. Sign in from a terminal, then try again.", bundle: .module)
      case .unavailable(let agent, .outdated):
        LocalizedStringResource(
          "\(agent) is too old to make a theme. Update it, then try again.", bundle: .module)
      case .timedOut(let agent):
        LocalizedStringResource(
          "\(agent) did not answer in time. The theme on screen is unchanged.", bundle: .module)
      case .failed(let agent):
        LocalizedStringResource(
          "\(agent) could not make the theme. The theme on screen is unchanged.", bundle: .module)
      case .invalid(let agent):
        LocalizedStringResource(
          "\(agent) twice gave a theme that could not be read. The theme on screen is unchanged: try again, or say it differently.",
          bundle: .module)
      case .couldNotSave:
        LocalizedStringResource("The theme could not be saved.", bundle: .module)
      case .couldNotDelete:
        LocalizedStringResource("The theme could not be deleted.", bundle: .module)
      case .couldNotExport:
        LocalizedStringResource("The theme could not be exported.", bundle: .module)
      }
    }
  }

  /// How a generation ended, for the diagnostics.
  enum Outcome: String, DiagnosticTokenConvertible {
    case applied, invalid, timedOut, unavailable, failed, cancelled
  }

  public private(set) var personal: [ConversationTheme] = []
  /// Files of the library that could not be read.
  public private(set) var loadProblems: [ThemeLoadProblem] = []
  /// The agents that can make a theme now.
  public private(set) var options: [ThemeGeneratorOption] = []
  public private(set) var optionsLoaded = false

  /// Whether the panel that makes a theme is unfolded.
  public private(set) var isOpen = false
  /// The mode the theme is made for. Fixed once a version exists: another mode is another theme.
  public var targetDark = false
  /// What the user is writing for the next version.
  public var prompt = ""
  public private(set) var versions: [Version] = []
  /// The name the theme will be saved under: the agent's, until the user writes one.
  public private(set) var name = ""
  @ObservationIgnored private var nameEdited = false
  /// Whether saving gives the theme its own accent, in place of the one the user chose.
  public var usesThemeAccent = true
  /// The agent at work, if any.
  public private(set) var generatingAgent: String?
  /// Whether the agent's first answer was refused and it is asked again.
  public private(set) var isRetrying = false
  public private(set) var problem: Problem?
  /// The last theme saved, until something else happens: what the confirmation under the grid
  /// says.
  public private(set) var lastSaved: (name: String, mode: SavedMode)?
  /// Whether a theme is being written: nothing else is done meanwhile.
  public private(set) var isSaving = false

  /// Where a theme saved is used.
  public enum SavedMode: Sendable {
    case light, dark
    /// The settings do not follow the system: the one theme is used whatever the mode.
    case always
  }

  @ObservationIgnored private let library: any ConversationThemeLibrary
  @ObservationIgnored private let generators: (any ThemeGeneratorResolving)?
  @ObservationIgnored private let fonts: (any ThemeFontResolving)?
  @ObservationIgnored private let diagnostics: Diagnostics
  @ObservationIgnored private let language: String
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private var currentRun: UUID?
  @ObservationIgnored var announce: @MainActor (LocalizedStringResource) -> Void = {
    AccessibilityNotification.Announcement(String(localized: $0)).post()
  }

  public init(
    library: any ConversationThemeLibrary = InMemoryConversationThemeLibrary(),
    generators: (any ThemeGeneratorResolving)? = nil, fonts: (any ThemeFontResolving)? = nil,
    diagnostics: Diagnostics = .disabled,
    language: String = Locale.preferredLanguages.first ?? "en"
  ) {
    self.library = library
    self.generators = generators
    self.fonts = fonts
    self.diagnostics = diagnostics
    self.language = language
  }

  /// The version on trial: the last one, while the panel is unfolded.
  public var trial: ConversationTheme? { isOpen ? versions.last?.theme : nil }

  public var isGenerating: Bool { generatingAgent != nil }

  /// Whether this build can make themes at all: a workspace assembled without agents cannot.
  public var canCreate: Bool { generators != nil }

  public var canGenerate: Bool {
    !isGenerating && !isSaving && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var canSave: Bool { !versions.isEmpty && !isGenerating && !isSaving }

  /// The theme the conversations are drawn with: the one on trial — with its own accent, which
  /// is what is being made — or the one the settings resolve to.
  public func displayed(
    _ appearance: ConversationAppearance, isDark: Bool, increasedContrast: Bool
  ) -> ConversationTheme {
    var theme: ConversationTheme
    if let trial {
      var own = appearance
      own.accent = .theme
      theme = trial.applying(own)
    } else {
      theme = ConversationTheme.resolve(
        appearance, isDark: isDark, increasedContrast: increasedContrast, personal: personal)
    }
    // A family the theme asks for that is not there — not fetched yet, or out of reach — gives
    // way to the system's family of its style.
    if let family = theme.messageFontFamily, !ConversationFonts.isInstalled(family) {
      theme.messageFontFamily = nil
    }
    if let family = theme.codeFontFamily, !ConversationFonts.isInstalled(family) {
      theme.codeFontFamily = nil
    }
    return theme
  }

  /// A theme by identifier, built in or the user's.
  public func theme(_ id: String) -> ConversationTheme? {
    ConversationTheme.named(id, personal: personal)
  }

  /// Reads the library again: when the tab appears, and after each change.
  public func load() async {
    let contents = await library.load()
    personal = contents.themes
    loadProblems = contents.problems
  }

  /// Asks which agents can make a theme now: each time the panel unfolds, and when asked again.
  public func refreshOptions() async {
    options = await generators?.options() ?? []
    optionsLoaded = true
  }

  public func location(ofFile fileName: String) -> URL? {
    library.location(ofFile: fileName)
  }

  // MARK: - The panel

  /// Unfolds the panel for a theme of the mode macOS is in, or folds it, dropping the trial.
  public func toggle(systemIsDark: Bool) {
    if isOpen {
      close()
    } else {
      open(systemIsDark: systemIsDark)
    }
  }

  public func open(systemIsDark: Bool) {
    guard !isOpen else { return }
    isOpen = true
    targetDark = systemIsDark
    lastSaved = nil
    problem = nil
    optionsLoaded = false
    Task { await refreshOptions() }
  }

  /// Folds the panel: what was generated and not saved is dropped, and a generation under way is
  /// stopped.
  public func close() {
    stopGeneration()
    let hadTrial = trial != nil
    isOpen = false
    versions = []
    prompt = ""
    name = ""
    nameEdited = false
    usesThemeAccent = true
    problem = nil
    if hadTrial {
      announce(LocalizedStringResource("The theme on trial was dropped.", bundle: .module))
    }
  }

  public func editName(_ newName: String) {
    name = newName
    nameEdited = true
  }

  /// Asks `option`'s agent for the next version: a new theme the first time, the current one
  /// changed afterwards.
  public func generate(with option: ThemeGeneratorOption) {
    let description = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty, !isGenerating else { return }
    let agent = option.descriptor.displayName
    let request = ThemeGenerationRequest(
      description: description, isDark: targetDark, language: language,
      current: versions.last?.theme, earlierRequests: versions.map(\.request))
    let run = UUID()
    currentRun = run
    generatingAgent = agent
    isRetrying = false
    problem = nil
    lastSaved = nil
    announce(
      versions.isEmpty
        ? LocalizedStringResource("\(agent) is making the theme.", bundle: .module)
        : LocalizedStringResource("\(agent) is changing the theme.", bundle: .module))
    let generate = GenerateConversationTheme(generator: option.generator, fonts: fonts)
    let started = ContinuousClock.now
    let attempts = AttemptCounter()
    // Held for the generation only: the model is not let go of while an agent works for it.
    let listen: @Sendable (GenerateConversationTheme.Event) -> Void = { [self] event in
      attempts.hear(event)
      Task { @MainActor in self.hear(event, run: run) }
    }
    task = Task { [weak self] in
      let result: Result<ConversationTheme, any Error>
      do {
        result = .success(
          try await generate(request, report: listen))
      } catch {
        result = .failure(error)
      }
      self?.finish(
        run: run, description: description, agent: agent, result: result,
        attempts: attempts.count, duration: ContinuousClock.now - started)
    }
  }

  private func hear(_ event: GenerateConversationTheme.Event, run: UUID) {
    guard currentRun == run, case .rejected(attempt: 1, _) = event else { return }
    isRetrying = true
    announce(
      LocalizedStringResource(
        "The theme could not be used as it was: it is asked again.", bundle: .module))
  }

  private func finish(
    run: UUID, description: String, agent: String, result: Result<ConversationTheme, any Error>,
    attempts: Int, duration: Duration
  ) {
    let outcome: Outcome
    switch result {
    case .success(let theme):
      outcome = currentRun == run ? .applied : .cancelled
      if currentRun == run {
        versions.append(Version(request: description, agentName: agent, theme: theme))
        prompt = ""
        if !nameEdited { name = theme.personalName ?? "" }
        announce(
          LocalizedStringResource("Version \(versions.count) is on trial.", bundle: .module))
      }
    case .failure(let error):
      switch error {
      case is CancellationError: outcome = .cancelled
      case ThemeGenerationError.invalid: outcome = .invalid
      case ThemeGenerationError.timedOut: outcome = .timedOut
      case ThemeGenerationError.unavailable: outcome = .unavailable
      default: outcome = .failed
      }
      if currentRun == run, outcome != .cancelled {
        problem = Self.problem(of: error, agent: agent)
        if let problem { announce(problem.message) }
      }
    }
    diagnostics.record(
      .session, .info, "theme.generation",
      [
        "outcome": .token(outcome.diagnosticToken), "attempts": .count(attempts),
        "duration": .duration(duration), "descriptionLength": .count(description.count),
      ])
    guard currentRun == run else { return }
    currentRun = nil
    generatingAgent = nil
    isRetrying = false
    task = nil
  }

  static func problem(of error: any Error, agent: String) -> Problem {
    switch error {
    case ThemeGenerationError.unavailable(let why): .unavailable(agent: agent, why)
    case ThemeGenerationError.timedOut: .timedOut(agent: agent)
    case ThemeGenerationError.invalid: .invalid(agent: agent)
    default: .failed(agent: agent)
    }
  }

  /// Stops the generation under way: the version on trial stays.
  public func cancel() {
    guard isGenerating else { return }
    stopGeneration()
    announce(LocalizedStringResource("The generation was cancelled.", bundle: .module))
  }

  private func stopGeneration() {
    task?.cancel()
    task = nil
    currentRun = nil
    generatingAgent = nil
    isRetrying = false
  }

  /// Back to the version before the last, the request that made the last one given back to be
  /// said again differently.
  public func back() {
    guard !isGenerating, let last = versions.popLast() else { return }
    prompt = last.request
    problem = nil
    if versions.isEmpty, !nameEdited { name = "" }
    announce(
      versions.isEmpty
        ? LocalizedStringResource("No version is on trial any more.", bundle: .module)
        : LocalizedStringResource("Version \(versions.count) is on trial.", bundle: .module))
  }

  /// Every version dropped: a theme from nothing again, of any mode.
  public func restart() {
    guard !isGenerating else { return }
    versions = []
    prompt = ""
    name = ""
    nameEdited = false
    problem = nil
  }

  /// Keeps the version on trial under `name`, gives it to the mode it was made for, and folds the
  /// panel. The appearance to put in force, `nil` when nothing was saved.
  public func save(into appearance: ConversationAppearance) async -> ConversationAppearance? {
    guard canSave, let version = versions.last else { return nil }
    isSaving = true
    defer { isSaving = false }
    let kept: ConversationTheme
    do {
      kept = try await library.save(version.theme, name: name)
    } catch {
      problem = .couldNotSave
      announce(Problem.couldNotSave.message)
      return nil
    }
    var updated = appearance
    if updated.followsSystemAppearance, targetDark {
      updated.darkTheme = kept.id
    } else {
      updated.lightTheme = kept.id
    }
    if usesThemeAccent { updated.accent = .theme }
    await load()
    let savedName = kept.personalName ?? name
    let mode: SavedMode =
      !updated.followsSystemAppearance ? .always : targetDark ? .dark : .light
    versions = []
    close()
    lastSaved = (savedName, mode)
    announce(Self.savedSentence(savedName, mode))
    return updated
  }

  /// Deletes a theme of the user's. A mode that used it goes back to its default theme. The
  /// appearance to put in force, `nil` when nothing was deleted.
  public func delete(_ id: String, from appearance: ConversationAppearance) async
    -> ConversationAppearance?
  {
    let deletedName = theme(id)?.personalName ?? ""
    do {
      try await library.remove(id)
    } catch ThemeLibraryError.notFound {
      // Gone already — by another instance, or by hand: what the settings point at is cleared
      // all the same.
    } catch {
      problem = .couldNotDelete
      announce(Problem.couldNotDelete.message)
      return nil
    }
    var updated = appearance
    if updated.lightTheme == id { updated.lightTheme = ConversationAppearance.defaultLightTheme }
    if updated.darkTheme == id { updated.darkTheme = ConversationAppearance.defaultDarkTheme }
    await load()
    lastSaved = nil
    announce(LocalizedStringResource("\(deletedName) is deleted.", bundle: .module))
    return updated
  }

  /// The `.zip` of a theme of the user's, with `preview` as its picture.
  public func archive(_ id: String, preview: Data?) async -> Data? {
    do {
      return try await library.archive(id, preview: preview)
    } catch {
      problem = .couldNotExport
      announce(Problem.couldNotExport.message)
      return nil
    }
  }

  /// What is said, and shown under the grid, once a theme is saved.
  public static func savedSentence(_ name: String, _ mode: SavedMode) -> LocalizedStringResource {
    switch mode {
    case .light:
      LocalizedStringResource("\(name) is saved and used in light mode.", bundle: .module)
    case .dark:
      LocalizedStringResource("\(name) is saved and used in dark mode.", bundle: .module)
    case .always:
      LocalizedStringResource("\(name) is saved and applied.", bundle: .module)
    }
  }

  /// Forgets the confirmation of the last save: another card was chosen.
  public func dismissConfirmation() {
    lastSaved = nil
    if !isOpen { problem = nil }
  }
}

/// How many times the agent was asked, heard from wherever the generation runs.
private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0

  func hear(_ event: GenerateConversationTheme.Event) {
    guard case .attempt(let number) = event else { return }
    lock.withLock { attempts = number }
  }

  var count: Int { lock.withLock { attempts } }
}
