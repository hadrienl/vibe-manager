import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// What would have been heard.
@MainActor
final class RecordingSoundPlayer: AlertSoundPlaying {
  private(set) var played: [URL] = []
  private(set) var systemAlerts = 0

  func play(_ url: URL) { played.append(url) }
  func playSystemAlert() { systemAlerts += 1 }

  var count: Int { played.count + systemAlerts }
}

/// Where the notifications would find the sound, recorded.
private final class RecordingInstaller: NotificationSoundInstalling, @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  private var clears = 0

  var installed: [String] { lock.withLock { names } }
  var cleared: Int { lock.withLock { clears } }

  func install(_ source: URL, name: String) throws -> String {
    lock.withLock { names.append(name) }
    return "Test – \(name).wav"
  }

  func clear() { lock.withLock { clears += 1 } }
}

/// Answers the recipes it is given, in turn; fails when it has none.
private actor RecipeGenerator: AlertSoundGenerating {
  private var answers: [AlertSoundRecipe]
  private(set) var requests: [AlertSoundGenerationRequest] = []

  init(_ answers: [AlertSoundRecipe]) {
    self.answers = answers
  }

  func generate(_ request: AlertSoundGenerationRequest) async throws -> Data {
    requests.append(request)
    guard !answers.isEmpty else { throw AlertSoundGenerationError.failed("none left") }
    return answers.removeFirst().encoded()
  }
}

private struct FixedGenerators: AlertSoundGeneratorResolving {
  let generator: any AlertSoundGenerating

  func options() async -> [AlertSoundGeneratorOption] {
    [
      AlertSoundGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("codex"), displayName: "Codex"),
        generator: generator)
    ]
  }
}

/// A clock the test moves.
private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_000)
  var now: Date { lock.withLock { current } }
  func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@MainActor
@Suite("The alert sounds (#393)")
struct AlertSoundLibraryModelTests {
  private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AlertSoundModelTests-\(UUID().uuidString)", isDirectory: true)

  private func systemFolder() throws -> URL {
    let system = folder.appendingPathComponent("System", isDirectory: true)
    try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    for name in ["Glass", "Ping"] {
      try AlertSoundWave.encode([0, 0.3, 0], sampleRate: 8).write(
        to: system.appendingPathComponent("\(name).aiff"))
    }
    return system
  }

  private func model(
    library: InMemoryAlertSoundLibrary = InMemoryAlertSoundLibrary(),
    preferences: InMemoryAlertSoundPreferences = .init(),
    generator: (any AlertSoundGenerating)? = nil,
    installer: (any NotificationSoundInstalling)? = nil,
    player: RecordingSoundPlayer = RecordingSoundPlayer(), clock: Clock = Clock()
  ) throws -> AlertSoundLibraryModel {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = AlertSoundLibraryModel(
      library: library, preferences: preferences,
      generators: generator.map { FixedGenerators(generator: $0) }, installer: installer,
      player: player, systemSoundsDirectory: try systemFolder(),
      cacheDirectory: folder.appendingPathComponent("Cache", isDirectory: true), language: "fr",
      now: { clock.now })
    model.announce = { _ in }
    return model
  }

  private func composed(_ library: InMemoryAlertSoundLibrary) async throws -> AlertSoundEntry {
    try await library.add(
      AlertSoundEntry(
        name: "Carillon", origin: .composed(agent: "codex"), addedAt: Date(), duration: 1,
        recipe: BundledAlertSound.chime.recipe, requests: ["un carillon"]),
      wave: AlertSoundWave.encode(AlertSoundSynthesizer.render(BundledAlertSound.chime.recipe)))
  }

  @Test("The sounds of macOS are listed from their folder, by name")
  func systemSounds() async throws {
    let sounds = try model()
    await sounds.load()
    #expect(sounds.systemSounds == ["Glass", "Ping"])
    #expect(sounds.choices.prefix(2) == [.systemDefault, .none])
    #expect(sounds.choices.contains(.bundled("chime")))
  }

  @Test("A sound chosen and gone since plays the system's default, without changing the choice")
  func missing() async throws {
    let gone = AlertSoundChoice.custom(AlertSoundID())
    let preferences = InMemoryAlertSoundPreferences(alertSound: gone)
    let sounds = try model(preferences: preferences)
    await sounds.load()
    #expect(sounds.choice == gone)
    #expect(sounds.inUse == .systemDefault)
    #expect(sounds.notificationSound == .systemDefault)
    #expect(preferences.alertSound == gone)
  }

  @Test("Used, a sound is kept, and copied where the notifications find it")
  func use() async throws {
    let preferences = InMemoryAlertSoundPreferences()
    let installer = RecordingInstaller()
    let sounds = try model(preferences: preferences, installer: installer)
    await sounds.load()
    sounds.use(.macOS("Glass"))
    await sounds.installTask?.value
    #expect(preferences.alertSound == .macOS("Glass"))
    #expect(installer.installed == ["Glass"])
    #expect(sounds.notificationSound == .named("Test – Glass.wav"))

    sounds.use(.bundled("drop"))
    await sounds.installTask?.value
    #expect(installer.installed.last == AlertSoundPresentation.name(of: .drop))

    sounds.use(.none)
    await sounds.installTask?.value
    #expect(sounds.notificationSound == .none)
    #expect(installer.cleared > 0)
  }

  @Test("Several alerts at once sound once; a second later, again")
  func throttled() async throws {
    let player = RecordingSoundPlayer()
    let clock = Clock()
    let sounds = try model(player: player, clock: clock)
    await sounds.load()
    sounds.playAlert()
    sounds.playAlert()
    #expect(player.systemAlerts == 1)
    clock.advance(1.5)
    sounds.playAlert()
    #expect(player.systemAlerts == 2)
  }

  @Test("None plays nothing")
  func silent() async throws {
    let player = RecordingSoundPlayer()
    let sounds = try model(preferences: .init(alertSound: .none), player: player)
    await sounds.load()
    sounds.playAlert()
    #expect(player.count == 0)
  }

  @Test("Selecting a sound plays it; a shipped one is played from its cache")
  func select() async throws {
    let player = RecordingSoundPlayer()
    let sounds = try model(player: player)
    await sounds.load()
    sounds.select(.sound(.bundled("tick")))
    while player.played.isEmpty { await Task.yield() }
    #expect(player.played.first?.lastPathComponent.hasPrefix("tick-") == true)
    #expect(sounds.preferences(is: .systemDefault))
  }

  @Test("Deleting the sound in use puts the system's default back")
  func removeInUse() async throws {
    let library = InMemoryAlertSoundLibrary(folder: folder)
    let preferences = InMemoryAlertSoundPreferences()
    let sounds = try model(library: library, preferences: preferences)
    let entry = try await composed(library)
    await sounds.load()
    sounds.use(.custom(entry.id))
    #expect(sounds.inUse == .custom(entry.id))
    await sounds.remove(entry.id)
    #expect(sounds.choice == .systemDefault)
    #expect(preferences.alertSound == .systemDefault)
    #expect(sounds.entries.isEmpty)
  }

  @Test("Composed: added to the user's own, selected and played, not put in use")
  func generate() async throws {
    let library = InMemoryAlertSoundLibrary(folder: folder)
    let player = RecordingSoundPlayer()
    var recipe = BundledAlertSound.drop.recipe
    recipe.name = "Goutte douce"
    let generator = RecipeGenerator([recipe])
    let sounds = try model(library: library, generator: generator, player: player)
    await sounds.load()
    await sounds.refreshOptions()
    sounds.description = "une goutte d'eau"
    #expect(sounds.canGenerate)
    sounds.generate()
    #expect(sounds.description.isEmpty)
    #expect(sounds.work?.request == "une goutte d'eau")
    await sounds.task?.value
    let entry = try #require(sounds.entries.first)
    #expect(entry.name == "Goutte douce")
    #expect(entry.origin == .composed(agent: "codex"))
    #expect(entry.requests == ["une goutte d'eau"])
    #expect(sounds.selection == .sound(.custom(entry.id)))
    #expect(sounds.inUse == .systemDefault)
    #expect(sounds.versions[entry.id]?.count == 1)
    while player.played.isEmpty { await Task.yield() }
    #expect(await generator.requests.first?.language == "fr")
  }

  @Test("Changed: the agent starts from the current recipe; each version can be put back")
  func change() async throws {
    let library = InMemoryAlertSoundLibrary(folder: folder)
    var lower = BundledAlertSound.chime.recipe
    lower.voices[0].notes[0].pitch = "E4"
    let generator = RecipeGenerator([BundledAlertSound.chime.recipe, lower])
    let sounds = try model(library: library, generator: generator)
    await sounds.load()
    await sounds.refreshOptions()
    sounds.description = "un carillon"
    sounds.generate()
    await sounds.task?.value
    let id = try #require(sounds.entries.first?.id)

    sounds.change = "plus grave"
    #expect(sounds.canChange)
    sounds.generateChange()
    await sounds.task?.value
    let asked = try #require(await generator.requests.last)
    #expect(asked.current == BundledAlertSound.chime.recipe)
    #expect(asked.earlierRequests == ["un carillon"])
    #expect(sounds.entry(id)?.recipe == lower)
    #expect(sounds.entry(id)?.requests == ["un carillon", "plus grave"])
    let versions = try #require(sounds.versions[id])
    #expect(versions.map(\.request) == ["un carillon", "plus grave"])
    #expect(sounds.currentVersion[id] == versions[1].id)

    await sounds.restore(versions[0], of: id)
    #expect(sounds.entry(id)?.recipe == BundledAlertSound.chime.recipe)
    #expect(sounds.currentVersion[id] == versions[0].id)
    #expect(sounds.entries.count == 1)
  }

  @Test("A failure stays listed with why, to try again or remove")
  func failure() async throws {
    let generator = RecipeGenerator([])
    let sounds = try model(generator: generator)
    await sounds.load()
    await sounds.refreshOptions()
    sounds.description = "un gong"
    sounds.generate()
    await sounds.task?.value
    let job = try #require(sounds.jobs.first)
    guard case .failed(.failed, _) = job.phase else {
      Issue.record("Not failed: \(job.phase)")
      return
    }
    #expect(sounds.problem == .generation(.failed("none left")))
    #expect(sounds.entries.isEmpty)
    sounds.dismiss(job.id)
    #expect(sounds.jobs.isEmpty)
  }

  @Test("Cancelled: nothing is written")
  func cancel() async throws {
    let sounds = try model(generator: RecipeGenerator([BundledAlertSound.drop.recipe]))
    await sounds.load()
    await sounds.refreshOptions()
    sounds.description = "un tic"
    sounds.generate()
    sounds.cancel()
    #expect(sounds.jobs.isEmpty)
    #expect(sounds.selection == .sound(.systemDefault))
    await sounds.refresh()
    #expect(sounds.entries.isEmpty)
  }
}

extension AlertSoundLibraryModel {
  /// Whether the choice kept is `choice`.
  fileprivate func preferences(is choice: AlertSoundChoice) -> Bool {
    self.choice == choice
  }
}
