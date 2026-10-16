import AppKit
import Foundation
import Observation
import VibeApplication

/// Plays a sound (#393): the application's speaker, in the tests a recorder.
@MainActor
public protocol AlertSoundPlaying: AnyObject {
  /// A sound file.
  func play(_ url: URL)
  /// The alert sound chosen in System Settings.
  func playSystemAlert()
}

/// The sound a notification carries.
public enum NotificationAlertSound: Equatable, Sendable {
  case systemDefault
  case none
  /// A file the notifications find: the name to give them.
  case named(String)
}

/// The sound played when a session out of sight needs the user, and the sounds it is chosen from
/// (#393): the system's default, none, those shipped, those of macOS, and the user's own —
/// imported, or composed by an agent and changed as asked.
///
/// Held by the application's model, as the avatars are: closing Settings does not stop a
/// composition, and the notifications ask it for their sound.
@MainActor
@Observable
public final class AlertSoundLibraryModel {
  /// What the screen says went wrong.
  public enum Problem: Equatable, Sendable {
    /// A file refused, by its name.
    case importing(AlertSoundImportProblem, file: String)
    case limitReached
    case generation(AlertSoundGenerationError)
    /// The library could not be read or written.
    case writing
    case renaming
    case deleting
  }

  /// What the list selects: a sound, or a composition that is not one yet.
  public enum Selection: Hashable, Sendable {
    case sound(AlertSoundChoice)
    case job(UUID)
  }

  /// A composition, under way or failed. One under way is the only one; one that failed stays
  /// listed for the run, to try again or remove.
  public struct Job: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
      case running
      case failed(AlertSoundGenerationError, at: Date)
    }

    public let id: UUID
    /// What the user asked: the description of a new sound, or the change of `target`.
    public let request: String
    /// The sound it changes; `nil` for a new one.
    public let target: AlertSoundID?
    public let provider: AgentProviderID
    public let startedAt: Date
    public var phase: Phase

    public var isUnderWay: Bool { phase == .running }
  }

  /// A version of a composed sound, made during this run: each can be heard, and put back.
  public struct Version: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// What was asked to make it: the description, then each change.
    public let request: String
    public let recipe: AlertSoundRecipe
  }

  // MARK: - State

  /// The user's own sounds, in the order they entered the library.
  public private(set) var entries: [AlertSoundEntry] = []
  /// The sounds of macOS, by name.
  public private(set) var systemSounds: [String] = []
  /// The sound chosen. It may be missing — deleted, or a disk gone: `inUse` says what plays.
  public private(set) var choice: AlertSoundChoice
  public private(set) var selection: Selection?
  /// The shape of each sound, for the list and the preview, from 0 to 1; and how long it lasts.
  public private(set) var outlines: [AlertSoundChoice: [Float]] = [:]
  public private(set) var durations: [AlertSoundChoice: Double] = [:]

  /// The description of a new sound, in the card.
  public var description = ""
  /// The change asked of the selected sound.
  public var change = ""
  public var selectedProvider: AgentProviderID?
  public private(set) var options: [AlertSoundGeneratorOption] = []
  public private(set) var jobs: [Job] = []
  /// The versions of each composed sound made during this run, oldest first.
  public private(set) var versions: [AlertSoundID: [Version]] = [:]
  /// The version each composed sound plays now, among `versions`.
  public private(set) var currentVersion: [AlertSoundID: UUID] = [:]
  public private(set) var isImporting = false
  public private(set) var problem: Problem?

  @ObservationIgnored private let library: any AlertSoundLibrary
  @ObservationIgnored private let preferences: any AlertSoundPreferences
  @ObservationIgnored private let decoder: (any AlertSoundDecoding)?
  @ObservationIgnored private let generators: (any AlertSoundGeneratorResolving)?
  @ObservationIgnored private let installer: (any NotificationSoundInstalling)?
  @ObservationIgnored private let player: (any AlertSoundPlaying)?
  @ObservationIgnored private let systemSoundsDirectory: URL?
  @ObservationIgnored private let cacheDirectory: URL
  @ObservationIgnored private let language: String
  @ObservationIgnored private let now: @Sendable () -> Date
  /// The name the notifications are given for the sound in use, once copied where they find it.
  @ObservationIgnored private(set) var installedName: String?
  /// The file a version was last heard from.
  @ObservationIgnored private var versionPreview: URL?
  /// When an alert last sounded: several at once sound once.
  @ObservationIgnored private var lastAlert: Date?
  /// The composition under way: the tests wait for it rather than for a length of time.
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private var currentRun: UUID?
  /// The copy of the sound in use for the notifications, under way: the tests wait for it.
  @ObservationIgnored private(set) var installTask: Task<Void, Never>?
  /// The reading of the shapes under way: the tests wait for it.
  @ObservationIgnored private(set) var outlineTask: Task<Void, Never>?
  /// Says a sentence to VoiceOver. The tests listen in its place.
  @ObservationIgnored var announce: @MainActor (LocalizedStringResource) -> Void = {
    Announcer.announce($0)
  }

  /// The least time between two alerts.
  static let alertInterval: TimeInterval = 1
  /// The points of a shape.
  static let outlineCount = 72

  public init(
    library: any AlertSoundLibrary, preferences: any AlertSoundPreferences,
    decoder: (any AlertSoundDecoding)? = nil,
    generators: (any AlertSoundGeneratorResolving)? = nil,
    installer: (any NotificationSoundInstalling)? = nil, player: (any AlertSoundPlaying)? = nil,
    systemSoundsDirectory: URL? = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
    cacheDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VibeManager-sounds", isDirectory: true),
    language: String = Locale.preferredLanguages.first ?? "en",
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.library = library
    self.preferences = preferences
    self.decoder = decoder
    self.generators = generators
    self.installer = installer
    self.player = player
    self.systemSoundsDirectory = systemSoundsDirectory
    self.cacheDirectory = cacheDirectory
    self.language = language
    self.now = now
    choice = preferences.alertSound
  }

  // MARK: - Reading

  /// Reads the library and the sounds of macOS, and puts the sound in use where the notifications
  /// find it.
  public func load() async {
    systemSounds = Self.soundNames(in: systemSoundsDirectory)
    await refresh()
    if selection == nil { selection = .sound(inUse) }
  }

  /// Reads the library again: after a change, or when the page comes back.
  public func refresh() async {
    if let entries = try? await library.entries() { self.entries = entries }
    if case .job(let id) = selection, job(id) == nil { selection = .sound(inUse) }
    if case .sound(let choice) = selection, !isAvailable(choice) { selection = .sound(inUse) }
    installInUse()
  }

  /// The sound that plays: the one chosen, or the system's default while it is missing.
  public var inUse: AlertSoundChoice {
    isAvailable(choice) ? choice : .systemDefault
  }

  /// Whether a sound is there to be played.
  public func isAvailable(_ choice: AlertSoundChoice) -> Bool {
    switch choice {
    case .systemDefault, .none: true
    case .bundled(let key): BundledAlertSound(rawValue: key) != nil
    case .macOS(let name): systemSounds.contains(name)
    case .custom(let id): entries.contains { $0.id == id }
    }
  }

  public func entry(_ id: AlertSoundID) -> AlertSoundEntry? {
    entries.first { $0.id == id }
  }

  public func job(_ id: UUID) -> Job? {
    jobs.first { $0.id == id }
  }

  /// The composition under way.
  public var work: Job? { jobs.first(where: \.isUnderWay) }

  public var selectedSound: AlertSoundChoice? {
    guard case .sound(let choice) = selection else { return nil }
    return choice
  }

  /// The selected sound of the user's own.
  public var selectedEntry: AlertSoundEntry? {
    guard case .custom(let id) = selectedSound else { return nil }
    return entry(id)
  }

  /// Every sound the menu offers, in its order: the default, none, the user's own, those shipped,
  /// those of macOS.
  public var choices: [AlertSoundChoice] {
    [.systemDefault, .none] + entries.map { .custom($0.id) }
      + BundledAlertSound.allCases.map { .bundled($0.rawValue) }
      + systemSounds.map { .macOS($0) }
  }

  /// What all of the user's own sounds take on disk.
  public var byteCount: Int64 { entries.reduce(0) { $0 + $1.byteCount } }

  /// The names of the sounds of a folder, without their extension, in alphabetical order.
  static func soundNames(in directory: URL?) -> [String] {
    guard let directory,
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    let audio: Set<String> = ["aiff", "aif", "caf", "wav", "m4a"]
    return names.filter { audio.contains(($0 as NSString).pathExtension.lowercased()) }
      .map { ($0 as NSString).deletingPathExtension }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  // MARK: - Files

  /// The file of a sound; `nil` for the default and none, or when it cannot be found.
  public func fileURL(of choice: AlertSoundChoice) async -> URL? {
    switch choice {
    case .systemDefault, .none:
      return nil
    case .custom(let id):
      return try? await library.fileURL(of: id)
    case .macOS(let name):
      guard let directory = systemSoundsDirectory else { return nil }
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      return names.first { ($0 as NSString).deletingPathExtension == name }
        .map { directory.appendingPathComponent($0) }
    case .bundled(let key):
      guard let sound = BundledAlertSound(rawValue: key) else { return nil }
      let cache = cacheDirectory
      return await Task.detached { Self.bundledFile(sound, in: cache) }.value
    }
  }

  /// A shipped sound, played once into the cache, then read from there — away from the main
  /// actor. Named after its recipe: a later version that changes it plays it again.
  nonisolated static func bundledFile(_ sound: BundledAlertSound, in cacheDirectory: URL) -> URL? {
    let url = cacheDirectory.appendingPathComponent(
      "\(sound.rawValue)-\(fingerprint(sound.recipe.encoded())).wav")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try AlertSoundWave.encode(AlertSoundSynthesizer.render(sound.recipe)).write(
        to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  /// FNV-1a: the same bytes give the same name on every launch.
  nonisolated static func fingerprint(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  // MARK: - Shapes

  /// Reads the shape of every sound, in the background: the page asks when it appears.
  public func showOutlines() {
    let previous = outlineTask
    outlineTask = Task { [weak self] in
      await previous?.value
      await self?.loadOutlines()
    }
  }

  private func loadOutlines() async {
    for choice in choices where outlines[choice] == nil {
      guard let sound = await decoded(choice) else { continue }
      outlines[choice] = AlertSoundWave.outline(of: sound.samples, count: Self.outlineCount)
      durations[choice] = sound.duration
    }
  }

  /// Reads a sound again after it changed.
  private func forgetOutline(_ choice: AlertSoundChoice) {
    outlines[choice] = nil
    durations[choice] = nil
  }

  private func decoded(_ choice: AlertSoundChoice) async -> DecodedAlertSound? {
    switch choice {
    case .systemDefault, .none:
      return nil
    case .bundled(let key):
      guard let sound = BundledAlertSound(rawValue: key) else { return nil }
      return DecodedAlertSound(
        samples: AlertSoundSynthesizer.render(sound.recipe),
        sampleRate: AlertSoundSynthesizer.sampleRate)
    case .custom, .macOS:
      guard let url = await fileURL(of: choice) else { return nil }
      let decoder = decoder
      return await Task.detached {
        if let data = try? Data(contentsOf: url), let wave = AlertSoundWave.decode(data) {
          return DecodedAlertSound(samples: wave.samples, sampleRate: wave.sampleRate)
        }
        return try? decoder?.decode(url, maximumDuration: 60)
      }.value
    }
  }

  // MARK: - Playing

  /// Plays a sound once: chosen in the list or the menu, or asked with ▶.
  public func play(_ choice: AlertSoundChoice) {
    switch choice {
    case .none:
      return
    case .systemDefault:
      player?.playSystemAlert()
    default:
      Task {
        guard let url = await fileURL(of: choice) else { return }
        player?.play(url)
      }
    }
  }

  /// Plays a version of a composed sound, made during this run.
  public func play(_ version: Version) {
    // Played from the temporary folder, one file at a time: a version is kept only by the sound
    // it is put back in.
    if let versionPreview { try? FileManager.default.removeItem(at: versionPreview) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VibeManager-sound-version-\(version.id.uuidString).wav")
    do {
      try AlertSoundWave.encode(AlertSoundSynthesizer.render(version.recipe)).write(
        to: url, options: .atomic)
    } catch {
      return
    }
    versionPreview = url
    player?.play(url)
  }

  /// A session out of sight needs the user, and no notification says it with a sound: the sound
  /// in use, played here. Several at once sound once.
  public func playAlert() {
    let time = now()
    if let lastAlert, time.timeIntervalSince(lastAlert) < Self.alertInterval { return }
    lastAlert = time
    play(inUse)
  }

  /// The sound a notification carries: the one in use, once copied where the notifications find
  /// it — the system's default until then.
  public var notificationSound: NotificationAlertSound {
    switch inUse {
    case .systemDefault: .systemDefault
    case .none: .none
    default: installedName.map(NotificationAlertSound.named) ?? .systemDefault
    }
  }

  /// Copies the sound in use where the notifications find it — the copy away from the main
  /// actor. When the notifications play the system's sound, or none, the copy is removed only
  /// when `clearing`: the user changed the sound. Reading the library at launch never removes
  /// anything, so that another run of the application under the same name — a smoke test — never
  /// takes away the sound of the one the user runs.
  private func installInUse(clearing: Bool = false) {
    guard let installer else { return }
    let sound = inUse
    let previous = installTask
    installTask = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      switch sound {
      case .systemDefault, .none:
        if clearing { await Task.detached { installer.clear() }.value }
        installedName = nil
      default:
        guard let url = await fileURL(of: sound) else {
          installedName = nil
          return
        }
        let name = AlertSoundPresentation.name(of: sound, in: self)
        installedName = await Task.detached { try? installer.install(url, name: name) }.value
      }
    }
  }

  // MARK: - Choosing

  /// Selects a sound in the list, and plays it.
  public func select(_ selection: Selection?) {
    guard selection != self.selection else { return }
    self.selection = selection
    change = ""
    if case .sound(let choice) = selection { play(choice) }
  }

  /// Puts a sound in use: the notifications and the alerts play it from now on.
  public func use(_ choice: AlertSoundChoice) {
    guard isAvailable(choice) else { return }
    self.choice = choice
    preferences.alertSound = choice
    installInUse(clearing: true)
    announce(
      LocalizedStringResource(
        "\(AlertSoundPresentation.name(of: choice, in: self)) is the alert sound.",
        bundle: .module, comment: "Said once a sound is put in use."))
  }

  // MARK: - Importing

  /// Adds the sound of a file to the user's own, selected and played; refused with why.
  public func importFile(_ url: URL) async {
    guard let decoder, !isImporting else { return }
    isImporting = true
    problem = nil
    defer { isImporting = false }
    let gotAccess = url.startAccessingSecurityScopedResource()
    defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let entry = try await ImportAlertSound(decoder: decoder, library: library, now: now)(url)
      await refresh()
      select(.sound(.custom(entry.id)))
      showOutlines()
      announce(
        LocalizedStringResource(
          "\(entry.name) was added to your sounds.", bundle: .module,
          comment: "Said once an audio file was imported as a sound."))
    } catch {
      switch error {
      case .problem(let reason):
        problem = .importing(reason, file: url.lastPathComponent)
      case .library(.limitReached):
        problem = .limitReached
      case .library:
        problem = .writing
      }
    }
  }

  public func dismissProblem() {
    problem = nil
  }

  // MARK: - Changing

  public func rename(_ id: AlertSoundID, to name: String) async {
    do {
      try await library.rename(id, to: name)
    } catch {
      problem = .renaming
    }
    await refresh()
  }

  /// Deletes a sound of the user's own. The one in use gives its place to the system's default.
  public func remove(_ id: AlertSoundID) async {
    do {
      try await library.remove(id)
    } catch {
      problem = .deleting
      return
    }
    if choice == .custom(id) {
      choice = .systemDefault
      preferences.alertSound = .systemDefault
      installInUse(clearing: true)
    }
    versions[id] = nil
    currentVersion[id] = nil
    forgetOutline(.custom(id))
    if selection == .sound(.custom(id)) { selection = .sound(inUse) }
    await refresh()
  }

  /// The file of a sound of the user's own, to export.
  public func exportData(_ id: AlertSoundID) async -> Data? {
    guard let url = try? await library.fileURL(of: id) else { return nil }
    return try? Data(contentsOf: url)
  }

  // MARK: - Agents

  /// Which agents can compose now. Asked when the page opens.
  public func refreshOptions() async {
    guard let generators else { return }
    options = await generators.options()
    if selectedProvider == nil || !options.contains(where: { $0.id == selectedProvider }) {
      selectedProvider = options.first?.id
    }
  }

  private var selectedGenerator: (any AlertSoundGenerating)? {
    options.first { $0.id == selectedProvider }?.generator
  }

  public var isIdle: Bool { work == nil && !isImporting }

  public var canGenerate: Bool {
    isIdle && selectedGenerator != nil
      && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Whether the selected sound can be changed by an agent: one it composed.
  public var canChange: Bool {
    guard isIdle, selectedGenerator != nil, let entry = selectedEntry, entry.recipe != nil
    else { return false }
    return !change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Composes a new sound from the description, in the background. It is added to the user's
  /// own, selected and played; the description is emptied.
  public func generate() {
    guard canGenerate, let generator = selectedGenerator, let provider = selectedProvider else {
      return
    }
    let request = description.trimmingCharacters(in: .whitespacesAndNewlines)
    description = ""
    start(
      Job(
        id: UUID(), request: request, target: nil, provider: provider, startedAt: now(),
        phase: .running),
      with: generator, current: nil, earlier: [])
    selection = .job(jobs.last?.id ?? UUID())
  }

  /// Changes the selected sound as asked: a new version, which it plays from now on.
  public func generateChange() {
    guard canChange, let generator = selectedGenerator, let provider = selectedProvider,
      let entry = selectedEntry, let recipe = entry.recipe
    else { return }
    let request = change.trimmingCharacters(in: .whitespacesAndNewlines)
    change = ""
    start(
      Job(
        id: UUID(), request: request, target: entry.id, provider: provider, startedAt: now(),
        phase: .running),
      with: generator, current: recipe, earlier: entry.requests)
  }

  /// Starts a failed composition again, with the same words.
  public func retry(_ id: UUID) {
    guard isIdle, let failed = job(id), case .failed = failed.phase,
      let generator = selectedGenerator, let provider = selectedProvider
    else { return }
    jobs.removeAll { $0.id == id }
    let target = failed.target.flatMap(entry)
    start(
      Job(
        id: UUID(), request: failed.request, target: target?.id, provider: provider,
        startedAt: now(), phase: .running),
      with: generator, current: target?.recipe, earlier: target?.requests ?? [])
    if failed.target == nil { selection = .job(jobs.last?.id ?? UUID()) }
  }

  /// Removes a failed composition from the list.
  public func dismiss(_ id: UUID) {
    guard let job = job(id), !job.isUnderWay else { return }
    jobs.removeAll { $0.id == id }
    if selection == .job(id) { selection = .sound(inUse) }
  }

  /// Stops the composition under way: its process is stopped, nothing is written.
  public func cancel() {
    // Once its sound is being written, it is too late: what was made is not thrown away.
    guard let work, currentRun != nil else { return }
    currentRun = nil
    task?.cancel()
    task = nil
    jobs.removeAll { $0.id == work.id }
    if selection == .job(work.id) { selection = .sound(inUse) }
    announce(
      LocalizedStringResource(
        "The composition is cancelled: nothing was changed.", bundle: .module,
        comment: "Said when the user cancels the composition of a sound."))
  }

  private func start(
    _ job: Job, with generator: any AlertSoundGenerating, current: AlertSoundRecipe?,
    earlier: [String]
  ) {
    problem = nil
    jobs.append(job)
    announce(AlertSoundPresentation.startAnnouncement(of: job, in: self))
    let run = UUID()
    currentRun = run
    let request = AlertSoundGenerationRequest(
      description: job.request, language: language, current: current, earlierRequests: earlier)
    task = Task { [weak self] in
      do {
        let recipe = try await GenerateAlertSound(generator: generator)(request)
        await self?.finish(job, with: recipe, run: run)
      } catch let error as AlertSoundGenerationError {
        await self?.fail(job, error, run: run)
      } catch is CancellationError {
        // Cancelled by the user: `cancel` said so.
      } catch {
        await self?.fail(job, .failed("unexpected"), run: run)
      }
    }
  }

  private func finish(_ job: Job, with recipe: AlertSoundRecipe, run: UUID) async {
    guard currentRun == run else { return }
    currentRun = nil
    task = nil
    let samples = AlertSoundSynthesizer.render(recipe)
    let wave = AlertSoundWave.encode(samples)
    let duration = Double(samples.count) / Double(AlertSoundSynthesizer.sampleRate)
    let written: AlertSoundEntry
    do {
      if let target = job.target, let original = entry(target) {
        written = try await library.replace(
          target,
          with: AlertSoundEntry(
            id: target, name: original.name, origin: .composed(agent: job.provider.rawValue),
            addedAt: original.addedAt, duration: duration, recipe: recipe,
            requests: original.requests + [job.request]),
          wave: wave)
      } else {
        written = try await library.add(
          AlertSoundEntry(
            name: recipe.name, origin: .composed(agent: job.provider.rawValue), addedAt: now(),
            duration: duration, recipe: recipe, requests: [job.request]),
          wave: wave)
      }
    } catch {
      jobs.removeAll { $0.id == job.id }
      problem = (error as? AlertSoundLibraryError) == .limitReached ? .limitReached : .writing
      await refresh()
      return
    }
    jobs.removeAll { $0.id == job.id }
    let version = Version(id: UUID(), request: job.request, recipe: recipe)
    versions[written.id, default: []].append(version)
    currentVersion[written.id] = version.id
    let choice = AlertSoundChoice.custom(written.id)
    forgetOutline(choice)
    await refresh()
    // A new sound takes the eye; a change of the sound selected is heard where it is.
    if job.target == nil || selection == .sound(choice) {
      selection = .sound(choice)
      play(choice)
    }
    showOutlines()
    announce(
      LocalizedStringResource(
        "\(written.name) is ready.", bundle: .module,
        comment: "Said once an agent composed a sound, or changed one."))
  }

  private func fail(_ job: Job, _ error: AlertSoundGenerationError, run: UUID) async {
    guard currentRun == run else { return }
    currentRun = nil
    task = nil
    if let index = jobs.firstIndex(where: { $0.id == job.id }) {
      jobs[index].phase = .failed(error, at: now())
    }
    problem = .generation(error)
    announce(AlertSoundPresentation.message(for: .generation(error)))
  }

  /// Puts back a version made during this run: the sound plays it from now on.
  public func restore(_ version: Version, of id: AlertSoundID) async {
    guard isIdle, let original = entry(id), currentVersion[id] != version.id else { return }
    let samples = AlertSoundSynthesizer.render(version.recipe)
    do {
      _ = try await library.replace(
        id,
        with: AlertSoundEntry(
          id: id, name: original.name, origin: original.origin, addedAt: original.addedAt,
          duration: Double(samples.count) / Double(AlertSoundSynthesizer.sampleRate),
          recipe: version.recipe, requests: original.requests),
        wave: AlertSoundWave.encode(samples))
    } catch {
      problem = .writing
      return
    }
    currentVersion[id] = version.id
    forgetOutline(.custom(id))
    await refresh()
    play(.custom(id))
    showOutlines()
  }
}

/// The application's speaker.
@MainActor
public final class SystemAlertSoundPlayer: AlertSoundPlaying {
  /// The sound playing: kept until it ends, or it would stop at once.
  private var playing: NSSound?

  public init() {
    // Nothing to prepare: each sound is read when it plays.
  }

  public func play(_ url: URL) {
    playing?.stop()
    playing = NSSound(contentsOf: url, byReference: true)
    playing?.play()
  }

  public func playSystemAlert() {
    NSSound.beep()
  }
}
