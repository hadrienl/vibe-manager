import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// Answers each request with a theme of its own — the current one with another accent — or what
/// `answers` says, and keeps the requests.
private actor ThemeAgent: ConversationThemeGenerating {
  enum Answer {
    case theme(ConversationTheme)
    case data(Data)
    case failure(ThemeGenerationError)
    /// Waits until the generation is cancelled.
    case hang
  }

  private var answers: [Answer]
  private(set) var requests: [ThemeGenerationRequest] = []

  init(_ answers: [Answer] = []) {
    self.answers = answers
  }

  func generate(_ request: ThemeGenerationRequest) async throws -> Data {
    requests.append(request)
    let answer: Answer =
      answers.isEmpty ? .theme(Self.next(after: request)) : answers.removeFirst()
    switch answer {
    case .theme(let theme): return ConversationThemeFile.encode(theme)
    case .data(let data): return data
    case .failure(let error): throw error
    case .hang:
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
      throw CancellationError()
    }
  }

  static func next(after request: ThemeGenerationRequest) -> ConversationTheme {
    var theme = request.current ?? (request.isDark ? .night : .paper)
    theme.personalName = theme.personalName ?? (request.isDark ? "Forêt de nuit" : "Papier")
    theme.accent = theme.accent == "#F2B544" ? ConversationTheme.night.accent : "#F2B544"
    theme.onAccent = "#10131C"
    return theme
  }
}

private struct Agents: ThemeGeneratorResolving {
  let generators: [(String, any ConversationThemeGenerating)]

  func options() async -> [ThemeGeneratorOption] {
    generators.map { name, generator in
      ThemeGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID(name.lowercased()), displayName: name),
        generator: generator)
    }
  }
}

/// Draws pictures, or not, and keeps what it was asked.
private final class Painter: AvatarGeneratorResolving, AvatarGenerating, @unchecked Sendable {
  enum Behaviour { case draws, fails, absent, hangs }
  let behaviour: Behaviour
  private let lock = NSLock()
  private var asked: [String] = []

  init(_ behaviour: Behaviour = .draws) {
    self.behaviour = behaviour
  }

  var prompts: [String] { lock.withLock { asked } }

  func options() async -> [AvatarGeneratorOption] {
    guard behaviour != .absent else { return [] }
    return [
      AvatarGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("codex"), displayName: "Codex"),
        unavailability: nil, generator: self)
    ]
  }

  func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    lock.withLock { asked.append(request.prompt) }
    switch behaviour {
    case .draws, .absent: return Data("png".utf8)
    case .fails: throw AvatarGenerationError.noImage
    case .hangs:
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
      throw CancellationError()
    }
  }
}

/// A theme that asks for a picture.
private func pictured(prompt: String? = "blurred pines", url: String? = nil) -> ConversationTheme {
  var theme = ConversationTheme.night
  theme.personalName = "Forêt"
  theme.backdrop.imagePrompt = prompt
  theme.backdrop.imageURL = url
  theme.backdrop.veil = 0.7
  return theme
}

/// Fonts that could not be fetched when the theme was made, and can now.
private actor LateFonts: ThemeFontResolving {
  private(set) var asked: [String] = []

  func prepare(_ family: String) async -> FontAvailability {
    asked.append(family)
    return .available
  }
}

@MainActor
private final class Fixture {
  let agent: ThemeAgent
  let library: InMemoryConversationThemeLibrary
  let log = RecordingDiagnosticLog()
  let model: ConversationThemesModel
  var spoken: [String] = []

  let images: InMemoryThemeImageStore
  let painter: Painter
  let fonts = LateFonts()

  init(
    _ answers: [ThemeAgent.Answer] = [], themes: [ConversationTheme] = [],
    agents: Bool = true, painter: Painter = Painter(), fetched: Data? = Data("jpg".utf8)
  ) {
    agent = ThemeAgent(answers)
    self.painter = painter
    images = InMemoryThemeImageStore { url in
      guard let fetched, url.host == "example.com" else { throw ThemeImageError.unreachable }
      return fetched
    }
    library = InMemoryConversationThemeLibrary(themes: themes)
    model = ConversationThemesModel(
      library: library, generators: agents ? Agents(generators: [("Claude Code", agent)]) : nil,
      fonts: fonts, images: images, pictureAgents: painter,
      diagnostics: Diagnostics(log: log, pseudonym: .ephemeral()), language: "fr-FR")
    model.announce = { [weak self] in self?.spoken.append(String(localized: $0)) }
  }

  var option: ThemeGeneratorOption {
    get async { await Agents(generators: [("Claude Code", agent)]).options()[0] }
  }

  /// Opens the panel, waits for the agents, and asks for one version.
  func generate(_ prompt: String, dark: Bool = true) async throws {
    if !model.isOpen {
      model.open(systemIsDark: dark)
      try await until { self.model.optionsLoaded }
    }
    model.prompt = prompt
    model.generate(with: await option)
    try await until { !self.model.isGenerating }
  }

  /// Waits for a state, never for a delay: a slow runner only makes it longer.
  func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The state never came")
  }
}

@Suite("Making a theme with an agent (#118)")
@MainActor
struct ConversationThemesModelTests {
  @Test("A version is put on trial, the request emptied for the next one, the name offered")
  func firstVersion() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    let model = fixture.model
    #expect(model.versions.map(\.request) == ["une forêt la nuit"])
    #expect(model.versions.first?.agentName == "Claude Code")
    #expect(model.prompt.isEmpty)
    #expect(model.trial?.isPersonal == true)
    #expect(model.trial?.isDark == true)
    #expect(model.name == "Forêt de nuit")
    let request = try #require(await fixture.agent.requests.first)
    #expect(request.current == nil)
    #expect(request.language == "fr-FR")
    #expect(fixture.spoken == ["Claude Code is making the theme.", "Version 1 is on trial."])
  }

  @Test("The next request changes the version on trial, with what was asked before")
  func iteration() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    let first = try #require(fixture.model.trial)
    try await fixture.generate("accent ambre")
    let requests = await fixture.agent.requests
    #expect(requests[1].current == first)
    #expect(requests[1].earlierRequests == ["une forêt la nuit"])
    #expect(requests[1].description == "accent ambre")
    #expect(fixture.model.trial?.id == first.id)
    #expect(fixture.model.trial?.accent != first.accent)
  }

  @Test("Going back puts the previous version on trial, and gives the request back")
  func back() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    let first = fixture.model.trial
    try await fixture.generate("accent ambre")
    fixture.model.back()
    #expect(fixture.model.trial == first)
    #expect(fixture.model.prompt == "accent ambre")
    fixture.model.back()
    #expect(fixture.model.trial == nil)
    #expect(fixture.model.name.isEmpty)
  }

  @Test("A name written by the user is never replaced by the agent's")
  func editedName() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    fixture.model.editName("Ma forêt")
    try await fixture.generate("accent ambre")
    #expect(fixture.model.name == "Ma forêt")
  }

  @Test("Folding the panel drops the trial and every version")
  func fold() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    fixture.model.toggle(systemIsDark: true)
    #expect(!fixture.model.isOpen)
    #expect(fixture.model.trial == nil)
    #expect(fixture.model.versions.isEmpty)
    #expect(fixture.spoken.last == "The theme on trial was dropped.")
  }

  @Test("The trial shows its own accent; without one, the settings are resolved")
  func displayed() async throws {
    let personal = ConversationThemeLibraryRules.kept(.terminal, name: "Vert")
    let fixture = Fixture(themes: [personal])
    await fixture.model.load()
    let appearance = ConversationAppearance(darkTheme: personal.id, accent: .blue)
    let resolved = fixture.model.displayed(
      appearance, isDark: true, increasedContrast: false, reducedTransparency: false)
    #expect(resolved.id == personal.id)
    #expect(resolved.accent == ConversationTheme.accentColors[.blue]?.dark)
    try await fixture.generate("une forêt la nuit")
    let trial = fixture.model.displayed(
      appearance, isDark: false, increasedContrast: true, reducedTransparency: false)
    #expect(trial.id == fixture.model.trial?.id)
    #expect(trial.accent == fixture.model.trial?.accent)
  }

  @Test("A session's own theme is drawn in either mode, with the settings' accent (#274)")
  func sessionTheme() async {
    let fixture = Fixture()
    let appearance = ConversationAppearance(accent: .blue)
    for isDark in [false, true] {
      let theme = fixture.model.displayed(
        appearance, session: ConversationTheme.night.id, isDark: isDark, increasedContrast: false,
        reducedTransparency: false)
      #expect(theme.id == ConversationTheme.night.id)
      #expect(theme.accent == ConversationTheme.accentColors[.blue]?.dark)
    }
    let following = fixture.model.displayed(
      appearance, session: nil, isDark: true, increasedContrast: false, reducedTransparency: false)
    #expect(following.id == ConversationAppearance.defaultDarkTheme)
  }

  @Test("Contrast High replaces the settings' system theme, never one chosen for the session")
  func sessionThemeAndContrast() async {
    let fixture = Fixture()
    let appearance = ConversationAppearance()
    let chosen = fixture.model.displayed(
      appearance, session: ConversationTheme.systemLight.id, isDark: false,
      increasedContrast: true, reducedTransparency: false)
    #expect(chosen.id == ConversationTheme.systemLight.id)
    let following = fixture.model.displayed(
      appearance, session: nil, isDark: false, increasedContrast: true, reducedTransparency: false)
    #expect(following.id == ConversationTheme.highContrast.id)
  }

  @Test("A session's theme that is gone follows the settings, and the trial with them")
  func missingSessionTheme() async throws {
    let fixture = Fixture()
    let appearance = ConversationAppearance()
    let missing = fixture.model.displayed(
      appearance, session: "deleted", isDark: true, increasedContrast: false,
      reducedTransparency: false)
    #expect(missing.id == ConversationAppearance.defaultDarkTheme)
    try await fixture.generate("une forêt la nuit")
    let trial = try #require(fixture.model.trial)
    #expect(
      fixture.model.displayed(
        appearance, session: "deleted", isDark: true, increasedContrast: false,
        reducedTransparency: false
      )
      .id == trial.id)
    #expect(
      fixture.model.displayed(
        appearance, session: ConversationTheme.paper.id, isDark: true, increasedContrast: false,
        reducedTransparency: false
      ).id == ConversationTheme.paper.id)
  }

  @Test("A family the theme asks for is drawn when it is there, and gives way when it is not")
  func fonts() async {
    var present = ConversationThemeLibraryRules.kept(.night, name: "Menlo")
    present.fonts = ConversationTheme.Fonts(message: "Menlo", code: "Zz Absent Mono")
    let fixture = Fixture(themes: [present])
    await fixture.model.load()
    let theme = fixture.model.displayed(
      ConversationAppearance(darkTheme: present.id), isDark: true, increasedContrast: false,
      reducedTransparency: false)
    #expect(theme.messageFontFamily == "Menlo")
    #expect(theme.codeFontFamily == nil)
  }

  @Test("A family missing when the theme was made is asked for again when the themes are read")
  func lateFonts() async throws {
    var theme = ConversationThemeLibraryRules.kept(.night, name: "Hors ligne")
    theme.fonts = ConversationTheme.Fonts(message: "Zz Later Sans", code: "Menlo")
    let fixture = Fixture(themes: [theme])
    await fixture.model.load()
    try await fixture.until { fixture.model.fontsGeneration == 1 }
    #expect(await fixture.fonts.asked == ["Zz Later Sans"])
  }

  @Test("Saving keeps the theme, gives it to the mode it was made for, and folds the panel")
  func save() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    let appearance = ConversationAppearance(accent: .blue)
    let updated = try #require(await fixture.model.save(into: appearance))
    let kept = try #require(fixture.model.personal.first)
    #expect(updated.darkTheme == kept.id)
    #expect(updated.lightTheme == appearance.lightTheme)
    #expect(updated.accent == .theme)
    #expect(kept.personalName == "Forêt de nuit")
    #expect(!fixture.model.isOpen)
    #expect(fixture.model.trial == nil)
    #expect(fixture.model.lastSaved?.name == "Forêt de nuit")
    #expect(fixture.spoken.last == "Forêt de nuit is saved and used in dark mode.")
    #expect(await fixture.library.load().themes == [kept])
  }

  @Test(
    "Without following the system, a theme saved goes where every card goes; the accent can stay")
  func saveNotFollowing() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt la nuit")
    fixture.model.usesThemeAccent = false
    let appearance = ConversationAppearance(followsSystemAppearance: false, accent: .pink)
    let updated = try #require(await fixture.model.save(into: appearance))
    #expect(updated.lightTheme == fixture.model.personal.first?.id)
    #expect(updated.darkTheme == appearance.darkTheme)
    #expect(updated.accent == .pink)
    #expect(fixture.spoken.last == "Forêt de nuit is saved and applied.")
  }

  @Test("Deleting a theme in use gives each mode that used it its default theme")
  func delete() async throws {
    let personal = ConversationThemeLibraryRules.kept(.night, name: "Nuit")
    let fixture = Fixture(themes: [personal])
    await fixture.model.load()
    let appearance = ConversationAppearance(lightTheme: personal.id, darkTheme: personal.id)
    let updated = try #require(await fixture.model.delete(personal.id, from: appearance))
    #expect(updated.lightTheme == ConversationAppearance.defaultLightTheme)
    #expect(updated.darkTheme == ConversationAppearance.defaultDarkTheme)
    #expect(fixture.model.personal.isEmpty)
    #expect(fixture.spoken == ["Nuit is deleted."])
    let untouched = ConversationAppearance(lightTheme: "paper")
    #expect(await fixture.model.delete("personal-gone", from: untouched) == untouched)
  }

  @Test("A picture described is drawn by the agent that draws, and put on the version on trial")
  func drawnPicture() async throws {
    let fixture = Fixture([.theme(pictured())])
    try await fixture.generate("des arbres flous")
    let backdrop = try #require(fixture.model.trial?.backdrop)
    #expect(backdrop.image != nil)
    #expect(backdrop.localImage != nil)
    #expect(fixture.painter.prompts.first?.contains("blurred pines") == true)
    #expect(fixture.painter.prompts.first?.contains("sheet.png") == true)
    #expect(fixture.spoken.contains("Codex is drawing the picture."))
    #expect(fixture.spoken.last == "The picture is on trial.")
    #expect(!fixture.model.isGenerating)
  }

  @Test("A picture at an address the user gave is fetched")
  func fetchedPicture() async throws {
    let fixture = Fixture([.theme(pictured(prompt: nil, url: "https://example.com/a.jpg"))])
    try await fixture.generate("avec https://example.com/a.jpg en fond")
    #expect(fixture.model.trial?.backdrop.image != nil)
    #expect(fixture.painter.prompts.isEmpty)
    #expect(await fixture.images.count == 1)
  }

  @Test("Without a picture, the version is on trial all the same, and why is said")
  func noPicture() async throws {
    let absent = Fixture([.theme(pictured())], painter: Painter(.absent))
    try await absent.generate("des arbres flous")
    #expect(absent.model.trial != nil)
    #expect(absent.model.trial?.backdrop.image == nil)
    #expect(absent.model.problem == .noPictureAgent)

    let failing = Fixture([.theme(pictured())], painter: Painter(.fails))
    try await failing.generate("des arbres flous")
    #expect(failing.model.problem == .pictureFailed(agent: "Codex"))

    let unreachable = Fixture(
      [.theme(pictured(prompt: nil, url: "https://example.com/a.jpg"))], fetched: nil)
    try await unreachable.generate("avec https://example.com/a.jpg")
    #expect(unreachable.model.problem == .pictureUnreachable)
  }

  @Test("While the picture is drawn, nothing is saved; cancelled, the version stays without it")
  func cancelPicture() async throws {
    let fixture = Fixture([.theme(pictured())], painter: Painter(.hangs))
    fixture.model.open(systemIsDark: true)
    try await fixture.until { fixture.model.optionsLoaded }
    fixture.model.prompt = "des arbres flous"
    fixture.model.generate(with: await fixture.option)
    try await fixture.until { fixture.model.isMakingPicture }
    #expect(fixture.model.trial != nil)
    #expect(!fixture.model.canSave)
    fixture.model.cancel()
    #expect(!fixture.model.isGenerating)
    #expect(fixture.model.canSave)
    #expect(fixture.model.trial?.backdrop.image == nil)
  }

  @Test("A failure leaves the version on trial, and says why")
  func failure() async throws {
    let fixture = Fixture([
      .theme(ThemeAgent.next(after: .init(description: "", isDark: true, language: ""))),
      .failure(.timedOut),
    ])
    try await fixture.generate("une forêt la nuit")
    let first = fixture.model.trial
    try await fixture.generate("accent ambre")
    #expect(fixture.model.trial == first)
    #expect(fixture.model.versions.count == 1)
    #expect(fixture.model.problem == .timedOut(agent: "Claude Code"))
    #expect(fixture.model.prompt == "accent ambre")
  }

  @Test("An answer refused twice is said, after the second attempt is announced")
  func refused() async throws {
    var illegible = ConversationTheme.night
    illegible.personalName = "Gris"
    illegible.text = illegible.background
    let fixture = Fixture([.theme(illegible), .theme(illegible)])
    try await fixture.generate("gris")
    #expect(fixture.model.versions.isEmpty)
    #expect(fixture.model.problem == .invalid(agent: "Claude Code"))
    #expect(
      fixture.spoken.contains("The theme could not be used as it was: it is asked again."))
    let event = try #require(fixture.log.events(named: "theme.generation").first)
    #expect(event.value(of: "attempts") == .count(2))
    #expect(event.value(of: "outcome") == .token("invalid"))
  }

  @Test("A generation cancelled adds nothing, even if its answer comes later")
  func cancel() async throws {
    let fixture = Fixture([.hang])
    fixture.model.open(systemIsDark: true)
    try await fixture.until { fixture.model.optionsLoaded }
    fixture.model.prompt = "une forêt"
    fixture.model.generate(with: await fixture.option)
    #expect(fixture.model.isGenerating)
    fixture.model.cancel()
    #expect(!fixture.model.isGenerating)
    try await fixture.until { fixture.log.events(named: "theme.generation").count == 1 }
    #expect(fixture.model.versions.isEmpty)
    #expect(fixture.model.problem == nil)
    #expect(fixture.spoken.last == "The generation was cancelled.")
  }

  @Test("What the diagnostics hear holds no word the user wrote")
  func diagnostics() async throws {
    let fixture = Fixture()
    try await fixture.generate("une forêt secrète")
    let event = try #require(fixture.log.events(named: "theme.generation").first)
    #expect(event.value(of: "outcome") == .token("applied"))
    #expect(event.value(of: "descriptionLength") == .count(17))
    #expect(event.value(of: "attempts") == .count(1))
    let line = String(decoding: DiagnosticLine.encode(event, origin: .app), as: UTF8.self)
    #expect(!line.contains("forêt"))
  }

  @Test("Without agents, no theme can be made; with them, only theirs are offered")
  func options() async throws {
    let none = Fixture(agents: false)
    #expect(!none.model.canCreate)
    none.model.open(systemIsDark: false)
    try await none.until { none.model.optionsLoaded }
    #expect(none.model.options.isEmpty)
    let some = Fixture()
    #expect(some.model.canCreate)
    #expect(!some.model.canGenerate)
    some.model.prompt = "  "
    #expect(!some.model.canGenerate)
  }
}
