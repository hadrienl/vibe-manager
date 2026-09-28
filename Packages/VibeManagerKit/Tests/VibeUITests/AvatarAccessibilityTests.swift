import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeLocalizationTesting

@testable import VibeUI

/// PNGs that decode: one pixel high, as wide as asked.
private enum Faces {
  static func png(width: Int = 1) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
    return rep?.representation(using: .png, properties: [:]) ?? Data()
  }

  static func avatar(
    _ name: String, source: AvatarManifest.Source = .imported, description: String? = nil,
    missing: Set<AvatarExpression> = []
  ) -> AvatarSpriteSet {
    AvatarSpriteSet(
      manifest: AvatarManifest(
        name: name, source: source, provider: source == .generated ? "codex" : nil,
        description: description, createdAt: Date(timeIntervalSince1970: 1_790_424_000)),
      sprites: Dictionary(
        uniqueKeysWithValues: AvatarExpression.allCases.filter { !missing.contains($0) }.map {
          ($0, png())
        }))
  }
}

/// A sheet drawn becomes faces; an archive is the avatar the test puts in it, or none.
private final class Processing: AvatarImageProcessing, @unchecked Sendable {
  private let lock = NSLock()
  private var archived: AvatarSpriteSet?

  func archive(holding avatar: AvatarSpriteSet?) { lock.withLock { archived = avatar } }

  func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  {
    Dictionary(uniqueKeysWithValues: expressions.map { ($0, Faces.png(width: 2)) })
  }
  func sprite(fromImage data: Data, as expression: AvatarExpression, matching reference: Data?)
    throws -> Data
  { Faces.png(width: 3) }
  func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int) {
    guard let archived = lock.withLock({ archived }) else { throw AvatarProblem.archiveUnreadable }
    return (archived, 0)
  }
  func archive(_ avatar: AvatarSpriteSet) throws -> Data { Data() }
}

/// An agent the test holds until it lets it go, and whose answer it decides.
private final class Agent: AvatarGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var isHeld = false
  private var answer: Result<Data, AvatarGenerationError> = .success(Data("sheet".utf8))

  func hold() { lock.withLock { isHeld = true } }
  func release() { lock.withLock { isHeld = false } }
  func answer(_ answer: Result<Data, AvatarGenerationError>) {
    lock.withLock { self.answer = answer }
  }

  func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    while lock.withLock({ isHeld }) {
      if Task.isCancelled { throw AvatarGenerationError.failed("cancelled") }
      await Task.yield()
    }
    return try lock.withLock { answer }.get()
  }
}

/// A library whose avatar in use cannot be changed, as on a full disk: everything else goes
/// through.
private struct RefusingUse: AvatarLibrary {
  struct Refused: Error {}
  let library: InMemoryAvatarLibrary

  func entries() async throws -> [AvatarLibraryEntry] { try await library.entries() }
  func canCreate() async throws -> Bool { try await library.canCreate() }
  func load(_ id: AvatarID) async throws -> AvatarSpriteSet { try await library.load(id) }
  func thumbnail(_ id: AvatarID) async throws -> Data? { try await library.thumbnail(id) }
  func saveDraft(_ avatar: AvatarSpriteSet, basedOn: AvatarID?) async throws -> AvatarID {
    try await library.saveDraft(avatar, basedOn: basedOn)
  }
  func updateDraft(_ id: AvatarID, with avatar: AvatarSpriteSet) async throws {
    try await library.updateDraft(id, with: avatar)
  }
  func draftToComplete(_ id: AvatarID) async throws -> AvatarID {
    try await library.draftToComplete(id)
  }
  func keep(_ id: AvatarID) async throws -> AvatarID { try await library.keep(id) }
  func rename(_ id: AvatarID, to name: String) async throws {
    try await library.rename(id, to: name)
  }
  func duplicate(_ id: AvatarID) async throws -> AvatarID { try await library.duplicate(id) }
  func remove(_ id: AvatarID) async throws { try await library.remove(id) }
  func inUse() async throws -> AvatarID { try await library.inUse() }
  func setInUse(_ id: AvatarID) async throws { throw Refused() }
}

private struct Agents: AvatarGeneratorResolving {
  let agent: Agent

  func options() async -> [AvatarGeneratorOption] {
    [
      AvatarGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("codex"), displayName: "Codex"),
        unavailability: nil, generator: agent)
    ]
  }
}

/// What VoiceOver hears on the page of the avatars (#154): each row one element with its state,
/// its actions, the card, the expressions, and what is announced — in French.
///
/// SwiftUI builds the accessibility tree of a hosted view only for an assistive application: a
/// test finds none. The views hand VoiceOver what `AvatarLibraryPresentation` says, and the model
/// says its announcements through `announce`: those are what is tested here.
@Suite("Settings › Requests › Avatars, for VoiceOver", .timeLimit(.minutes(5)))
@MainActor
struct AvatarAccessibilityTests {
  private let agent = Agent()
  private let processing = Processing()
  private static let french: AvatarLibraryPresentation.Resolve = {
    Localization.string($0, in: "fr")
  }
  private static let fr = Locale(identifier: "fr_FR")

  /// What was said, in French, in order: the model's announcer, listened to in VoiceOver's place.
  private final class Heard {
    var sentences: [String] = []
  }

  /// The default avatar, a fox drawn by Codex and in use, a robot imported; and what they say.
  private func library(drafts: [AvatarSpriteSet] = [], refusesUse: Bool = false) async -> (
    AvatarLibraryModel, Heard
  ) {
    _ = NSApplication.shared
    let library = InMemoryAvatarLibrary(
      defaultAvatar: Faces.avatar("Default", source: .bundled),
      kept: [
        Faces.avatar(
          "Renard roux à écharpe bleue", source: .generated, description: "Un renard roux."),
        Faces.avatar("Robot rétro menthe"),
      ])
    let fox = try? await library.entries().first { $0.manifest?.name.hasPrefix("Renard") == true }
    if let fox { try? await library.setInUse(fox.id) }
    for draft in drafts {
      _ = try? await library.saveDraft(draft, basedOn: nil)
    }
    let avatars = AvatarLibraryModel(
      workshop: AvatarWorkshop(processing: processing),
      library: refusesUse ? RefusingUse(library: library) : library,
      generators: Agents(agent: agent))
    let heard = Heard()
    avatars.announce = { heard.sentences.append(Localization.string($0, in: "fr")) }
    await avatars.load()
    await avatars.refreshOptions()
    return (avatars, heard)
  }

  private func entry(_ avatars: AvatarLibraryModel, _ prefix: String) throws -> AvatarLibraryEntry {
    try #require(avatars.entries.first { $0.manifest?.name.hasPrefix(prefix) == true })
  }

  private func spoken(_ entry: AvatarLibraryEntry, _ avatars: AvatarLibraryModel, now: Date = .now)
    -> AvatarLibraryPresentation.Spoken
  {
    AvatarLibraryPresentation.spoken(
      entry, avatars: avatars, now: now, locale: Self.fr, resolve: Self.french)
  }

  // MARK: - Rows

  @Test("A row is read as its name, where it comes from, and its state")
  func rows() async throws {
    let (avatars, _) = await library(drafts: [
      Faces.avatar("Chouette", source: .generated, description: "Une chouette.")
    ])
    let date = Date(timeIntervalSince1970: 1_790_424_000).formatted(
      .dateTime.day().month(.wide).year().locale(Self.fr))

    let fox = spoken(try entry(avatars, "Renard"), avatars)
    #expect(fox.label == "Renard roux à écharpe bleue, dessiné par Codex le \(date)")
    #expect(date.contains("septembre 2026"))
    #expect(fox.value == "En usage")

    let robot = spoken(try entry(avatars, "Robot"), avatars)
    #expect(robot.label == "Robot rétro menthe, importé le \(date)")
    #expect(robot.value.isEmpty)

    let owl = spoken(try entry(avatars, "Chouette"), avatars)
    #expect(owl.value == "À valider")

    let byDefault = try #require(avatars.entry(.default))
    #expect(spoken(byDefault, avatars).label == "Avatar par défaut, fourni avec l’application")
    await avatars.use(.default)
    #expect(spoken(byDefault, avatars).value == "En usage")
  }

  @Test("An avatar that cannot be read, or lacks expressions, says so")
  func problems() async throws {
    let (avatars, _) = await library()
    var robot = try entry(avatars, "Robot")
    robot.problem = .unreadable
    #expect(spoken(robot, avatars).value == "Illisible")
    robot.problem = .incomplete([.worried])
    #expect(spoken(robot, avatars).value == "Incomplet, 1 expression manquante")
    robot.problem = .incomplete([.worried, .pleased])
    #expect(spoken(robot, avatars).value == "Incomplet, 2 expressions manquantes")
    robot.manifest = nil
    robot.problem = .unreadable
    // Nothing says where it comes from: its name alone.
    #expect(!spoken(robot, avatars).label.contains(","))
  }

  @Test("An avatar whose expression is drawn again says for how long")
  func redrawing() async throws {
    let (avatars, _) = await library()
    let fox = try entry(avatars, "Renard")
    await avatars.select(.avatar(fox.id))
    agent.hold()
    defer { agent.release() }
    avatars.regenerate(.pleased)
    let work = try #require(avatars.work)
    let later = work.startedAt.addingTimeInterval(42)
    #expect(
      spoken(fox, avatars, now: later).value
        == "En usage, Génération en cours, moins d’une minute")
    #expect(AvatarLibraryPresentation.rowActions(for: fox, avatars: avatars).contains(.cancel))
    // Being redrawn, it is not renamed: what comes back would bring its name back.
    #expect(!AvatarLibraryPresentation.rowActions(for: fox, avatars: avatars).contains(.rename))
    avatars.cancel()
  }

  @Test("How long a generation has run is said in whole minutes, not every second")
  func wholeMinutes() {
    func said(_ seconds: TimeInterval) -> String {
      // The space between the number and its unit is Foundation's: not what is tested here.
      AvatarLibraryPresentation.spokenElapsed(seconds, locale: Self.fr, resolve: Self.french)
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(said(0) == "moins d’une minute")
    #expect(said(59) == "moins d’une minute")
    #expect(said(60) == "1 minute")
    #expect(said(119) == "1 minute")
    #expect(said(150) == "2 minutes")
    // One reading a minute, on the minutes of the start: what is said changes no more often.
    let start = Date(timeIntervalSince1970: 1_790_424_000)
    let dates = AvatarLibraryPresentation.spokenSchedule(from: start)
      .entries(from: start.addingTimeInterval(1), mode: .normal).prefix(3)
    #expect(Array(dates) == [0, 60, 120].map { start.addingTimeInterval($0) })
  }

  @Test("A generation's row says how it goes: under way, failed, or not written")
  func jobs() {
    let started = Date(timeIntervalSince1970: 1_790_424_000)
    var job = AvatarLibraryModel.Job(
      id: UUID(), kind: .wholeSet, destination: .newDraft(basedOn: nil),
      description: "\n  Une chouette brune\nà lunettes", provider: AgentProviderID("codex"),
      startedAt: started, phase: .running)
    func spoken(_ now: Date) -> AvatarLibraryPresentation.Spoken {
      AvatarLibraryPresentation.spoken(job, now: now, locale: Self.fr, resolve: Self.french)
    }
    #expect(spoken(started.addingTimeInterval(42)).label == "Une chouette brune")
    #expect(
      spoken(started.addingTimeInterval(42)).value
        == "Génération en cours, moins d’une minute")
    job.phase = .writing
    #expect(spoken(started).value == "Enregistrement…")
    job.phase = .failed(.noImage, at: started)
    #expect(spoken(started.addingTimeInterval(120)).value == "Échec, il y a 2 minutes")
    job.phase = .unsaved(at: started)
    #expect(spoken(started).value == "Échec, Pas encore enregistré sur le disque")
    job = AvatarLibraryModel.Job(
      id: UUID(), kind: .wholeSet, destination: .newDraft(basedOn: nil), description: " ",
      provider: AgentProviderID("codex"), startedAt: started, phase: .running)
    #expect(spoken(started).label == "Nouvel avatar")
  }

  // MARK: - Actions

  @Test("VoiceOver offers on each row the actions its menu can do now")
  func rowActions() async throws {
    let (avatars, _) = await library(drafts: [Faces.avatar("Chouette")])
    let byDefault = try #require(avatars.entry(.default))
    // Not in use: used, duplicated, exported — never renamed nor deleted.
    #expect(
      AvatarLibraryPresentation.rowActions(for: byDefault, avatars: avatars)
        == [.use, .duplicate, .export, .exportWithoutDescription])
    let fox = try entry(avatars, "Renard")
    // In use: not used again.
    #expect(
      AvatarLibraryPresentation.rowActions(for: fox, avatars: avatars)
        == [.rename, .duplicate, .export, .exportWithoutDescription, .delete])
    let robot = try entry(avatars, "Robot")
    #expect(
      AvatarLibraryPresentation.rowActions(for: robot, avatars: avatars)
        == [.use, .rename, .duplicate, .export, .exportWithoutDescription, .delete])
    let owl = try entry(avatars, "Chouette")
    #expect(
      AvatarLibraryPresentation.rowActions(for: owl, avatars: avatars) == [.rename, .discard])
    var unreadable = robot
    unreadable.problem = .unreadable
    #expect(
      AvatarLibraryPresentation.rowActions(for: unreadable, avatars: avatars) == [.rename, .delete])

    let titles = AvatarLibraryPresentation.RowAction.allCases.map {
      Localization.string(AvatarLibraryPresentation.title(of: $0), in: "fr")
    }
    #expect(
      titles == [
        "Utiliser cet avatar", "Renommer…", "Dupliquer", "Exporter…",
        "Exporter sans la description…", "Supprimer…", "Abandonner…", "Annuler",
      ])
  }

  @Test("A generation's row offers Cancel while it runs; Try Again and Remove once it failed")
  func jobActions() async throws {
    let (avatars, _) = await library()
    agent.hold()
    avatars.description = "Une chouette"
    avatars.generate()
    let work = try #require(avatars.work)
    #expect(AvatarLibraryPresentation.jobActions(for: work, avatars: avatars) == [.cancel])
    agent.answer(.failure(.noImage))
    agent.release()
    await waitUntil("the failed generation") { avatars.failures.count == 1 }
    let failed = try #require(avatars.failures.first)
    #expect(
      AvatarLibraryPresentation.jobActions(for: failed, avatars: avatars) == [.retry, .remove])
    var unsaved = failed
    unsaved.phase = .unsaved(at: .now)
    #expect(
      AvatarLibraryPresentation.jobActions(for: unsaved, avatars: avatars) == [.saveAgain, .remove])
    let titles = AvatarLibraryPresentation.JobAction.allCases.map {
      Localization.string(AvatarLibraryPresentation.title(of: $0), in: "fr")
    }
    #expect(titles == ["Annuler", "Réessayer", "Réessayer l’enregistrement", "Retirer"])
  }

  // MARK: - The card and the expressions

  @Test("The card says whether it is unfolded, and why it is greyed out")
  func card() async throws {
    let folded = AvatarLibraryPresentation.spokenCard(
      isOpen: false, reason: nil, resolve: Self.french)
    #expect(folded == .init(label: "Créer un nouvel avatar", value: "Replié"))
    let unfolded = AvatarLibraryPresentation.spokenCard(
      isOpen: true, reason: nil, resolve: Self.french)
    #expect(unfolded.value == "Déplié")

    let (avatars, _) = await library()
    agent.hold()
    defer { agent.release() }
    avatars.description = "Une chouette"
    avatars.generate()
    let greyed = AvatarLibraryPresentation.spokenCard(
      isOpen: false, reason: AvatarLibraryPresentation.creationUnavailability(avatars),
      resolve: Self.french)
    #expect(greyed.value == "Replié, Disponible à la fin de la génération en cours")
    avatars.cancel()
  }

  @Test("An expression the avatar lacks is said missing, in words")
  func missingExpression() {
    let name = Localization.string(AvatarPresentation.name(of: .worried), in: "fr")
    #expect(
      AvatarLibraryPresentation.spokenExpression(.worried, isMissing: false, resolve: Self.french)
        == name)
    #expect(
      AvatarLibraryPresentation.spokenExpression(.worried, isMissing: true, resolve: Self.french)
        == "\(name), manquante")
  }

  // MARK: - Announcements

  @Test("A generation is announced as it starts and as it ends, once each")
  func generationAnnounced() async throws {
    let (avatars, heard) = await library()
    agent.hold()
    avatars.description = "Une chouette"
    avatars.generate()
    #expect(heard.sentences == ["Codex dessine l’avatar. Cela prend une à deux minutes."])
    agent.release()
    // Said once the draft is written and selected: the last thing the generation does.
    await waitUntil("the draft written, and said") { avatars.lastEvent != nil }
    #expect(
      heard.sentences == [
        "Codex dessine l’avatar. Cela prend une à deux minutes.",
        "L’avatar est prêt\u{00A0}: vérifiez-le, puis gardez-le.",
      ])
  }

  @Test("A generation that fails, or is cancelled, is announced once")
  func failureAnnounced() async throws {
    let (avatars, heard) = await library()
    agent.answer(.failure(.noImage))
    avatars.description = "Une chouette"
    avatars.generate()
    await waitUntil("the failure") { avatars.failures.count == 1 }
    #expect(heard.sentences.count == 2)
    #expect(
      heard.sentences.last
        == Localization.string(AvatarPresentation.message(for: .generation(.noImage)), in: "fr"))

    heard.sentences = []
    agent.hold()
    defer { agent.release() }
    avatars.retry(try #require(avatars.failures.first).id)
    avatars.cancel()
    #expect(
      heard.sentences == [
        "Codex dessine l’avatar. Cela prend une à deux minutes.",
        "La génération est annulée\u{00A0}: rien n’a été modifié.",
      ])
  }

  @Test("An import is announced as it starts and as it ends; a refused archive says why")
  func importAnnounced() async throws {
    let (avatars, heard) = await library()
    processing.archive(holding: Faces.avatar("Hibou"))
    await avatars.importArchive(Data("zip".utf8))
    #expect(
      heard.sentences == [
        "Lecture de l’archive…",
        "L’archive est importée\u{00A0}: vérifiez l’avatar, puis gardez-le.",
      ])

    heard.sentences = []
    processing.archive(holding: Faces.avatar("Hibou", missing: [.worried]))
    await avatars.importArchive(Data("zip".utf8))
    #expect(heard.sentences.last == "L’archive est importée, mais il lui manque des expressions.")

    heard.sentences = []
    processing.archive(holding: nil)
    await avatars.importArchive(Data("zip".utf8))
    #expect(
      heard.sentences == [
        "Lecture de l’archive…",
        Localization.string(
          AvatarPresentation.message(for: .archive(.archiveUnreadable)), in: "fr"),
      ])
  }

  @Test("Keeping, using and deleting are each announced once, with the avatar's name")
  func decisionsAnnounced() async throws {
    let (avatars, heard) = await library(drafts: [Faces.avatar("Chouette"), Faces.avatar("Hibou")])
    let owl = try entry(avatars, "Chouette")
    await avatars.select(.avatar(owl.id))
    await avatars.keep(owl.id)
    #expect(
      heard.sentences == [
        "L’avatar «\u{00A0}Chouette\u{00A0}» est gardé, et présente les demandes dans le panneau flottant."
      ])

    heard.sentences = []
    let hibou = try entry(avatars, "Hibou")
    await avatars.select(.avatar(hibou.id))
    avatars.usesKeptDraft = false
    await avatars.keep(hibou.id)
    #expect(heard.sentences == ["L’avatar «\u{00A0}Hibou\u{00A0}» est gardé."])

    heard.sentences = []
    let robot = try entry(avatars, "Robot")
    await avatars.use(robot.id)
    #expect(
      heard.sentences == [
        "L’avatar «\u{00A0}Robot rétro menthe\u{00A0}» présente maintenant les demandes dans le panneau flottant."
      ])

    heard.sentences = []
    await avatars.remove(robot.id)
    #expect(
      heard.sentences == [
        "L’avatar «\u{00A0}Robot rétro menthe\u{00A0}» est supprimé\u{00A0}: le panneau flottant reprend l’avatar par défaut."
      ])

    heard.sentences = []
    await avatars.remove(try entry(avatars, "Renard").id)
    #expect(
      heard.sentences == ["L’avatar «\u{00A0}Renard roux à écharpe bleue\u{00A0}» est supprimé."])
  }

  @Test("Kept, but not put in the panel: one sentence says both")
  func keptNotUsed() async throws {
    let (avatars, heard) = await library(drafts: [Faces.avatar("Chouette")], refusesUse: true)
    let owl = try entry(avatars, "Chouette")
    await avatars.select(.avatar(owl.id))
    await avatars.keep(owl.id)
    #expect(avatars.entry(owl.id)?.isDraft == false)
    #expect(avatars.problem == .using)
    #expect(
      heard.sentences == [
        "L’avatar «\u{00A0}Chouette\u{00A0}» est gardé, mais n’a pas pu être mis dans le panneau flottant\u{00A0}: le panneau garde le sien."
      ])
  }

  @Test("Deleting an avatar being redrawn says it is deleted, not that a generation was cancelled")
  func deletedWhileRedrawn() async throws {
    let (avatars, heard) = await library()
    let fox = try entry(avatars, "Renard")
    await avatars.select(.avatar(fox.id))
    agent.hold()
    defer { agent.release() }
    avatars.regenerate(.pleased)
    #expect(avatars.work?.avatar == fox.id)
    heard.sentences = []
    await avatars.remove(fox.id)
    #expect(avatars.work == nil)
    #expect(
      heard.sentences == [
        "L’avatar «\u{00A0}Renard roux à écharpe bleue\u{00A0}» est supprimé\u{00A0}: le panneau flottant reprend l’avatar par défaut."
      ])
  }

  @Test("A draft discarded is announced as discarded")
  func discardAnnounced() async throws {
    let (avatars, heard) = await library(drafts: [Faces.avatar("Chouette")])
    await avatars.discard(try entry(avatars, "Chouette").id)
    #expect(heard.sentences == ["L’avatar «\u{00A0}Chouette\u{00A0}» est abandonné."])
  }

  @Test("The library full: a new import is refused, and said")
  func fullAnnounced() async throws {
    let (avatars, heard) = await library(
      drafts: (0..<(AvatarLibraryRules.maximumCount - 2)).map { Faces.avatar("Copie \($0)") })
    #expect(!avatars.canCreate)
    await avatars.importArchive(Data("zip".utf8))
    #expect(
      heard.sentences == [
        Localization.string(AvatarPresentation.message(for: .limitReached), in: "fr")
      ])
  }

}
