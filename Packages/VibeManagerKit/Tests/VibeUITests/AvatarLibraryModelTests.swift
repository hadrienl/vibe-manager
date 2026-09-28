import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

/// PNGs that decode, told apart by their width: the default avatar's sprites are 1 pixel wide, a
/// generated sheet's 2, an expression drawn again 3, an archive's 4.
private enum Sprites {
  static func png(width: Int) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
    return rep?.representation(using: .png, properties: [:]) ?? Data()
  }

  static func set(
    _ name: String, width: Int, source: AvatarManifest.Source = .imported,
    description: String? = nil, missing: Set<AvatarExpression> = []
  ) -> AvatarSpriteSet {
    AvatarSpriteSet(
      manifest: AvatarManifest(name: name, source: source, description: description),
      sprites: Dictionary(
        uniqueKeysWithValues: AvatarExpression.allCases.filter { !missing.contains($0) }.map {
          ($0, png(width: width))
        }))
  }
}

/// Images that need no decoding of a real sheet.
private struct FakeProcessing: AvatarImageProcessing {
  var archived: AvatarSpriteSet?

  func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  {
    guard data == Data("sheet".utf8) else {
      throw AvatarProblem.wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1, height: 1)
    }
    return Dictionary(uniqueKeysWithValues: expressions.map { ($0, Sprites.png(width: 2)) })
  }

  func sprite(fromImage data: Data, as expression: AvatarExpression, matching reference: Data?)
    throws -> Data
  {
    Sprites.png(width: 3)
  }

  func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int) {
    guard let archived else { throw AvatarProblem.archiveUnreadable }
    return (archived, 2)
  }

  func archive(_ avatar: AvatarSpriteSet) throws -> Data {
    Data("\(avatar.manifest.name)|\(avatar.manifest.description ?? "")".utf8)
  }
}

/// An agent whose answers the test decides, and which it can hold until it lets it go: a
/// generation under way, whatever the screens do meanwhile.
private final class ScriptedGenerator: AvatarGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Result<Data, AvatarGenerationError>]
  private var isHeld = false

  init(_ answers: [Result<Data, AvatarGenerationError>] = [.success(Data("sheet".utf8))]) {
    self.answers = answers
  }

  /// Every generation from now on waits for `release()`, or for its cancellation.
  func hold() { lock.withLock { isHeld = true } }
  func release() { lock.withLock { isHeld = false } }
  /// What the next generations answer.
  func answer(_ answer: Result<Data, AvatarGenerationError>) {
    lock.withLock { answers = [answer] }
  }

  func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    while lock.withLock({ isHeld }) {
      // Cancelled while it launched its process: it fails, as a real one would.
      if Task.isCancelled { throw AvatarGenerationError.failed("no launch plan") }
      await Task.yield()
    }
    let answer = lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
    return try answer.get()
  }
}

private struct FakeGenerators: AvatarGeneratorResolving {
  let generator: ScriptedGenerator

  func options() async -> [AvatarGeneratorOption] {
    [
      AvatarGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("claude"), displayName: "Claude Code"),
        unavailability: .notCapable, generator: nil),
      AvatarGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("codex"), displayName: "Codex"),
        unavailability: nil, generator: generator),
    ]
  }
}

/// A library whose avatar in use is the one it is told, whatever it holds: one kept by another
/// version, that lost expressions or cannot be read since.
private struct ForcedInUse: AvatarLibrary {
  let library: InMemoryAvatarLibrary
  let inUseID: AvatarID
  var unreadable = false

  func entries() async throws -> [AvatarLibraryEntry] { try await library.entries() }
  func canCreate() async throws -> Bool { try await library.canCreate() }
  func load(_ id: AvatarID) async throws -> AvatarSpriteSet {
    if unreadable, id == inUseID { throw AvatarStoreError.unreadable }
    return try await library.load(id)
  }
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
  func inUse() async throws -> AvatarID { inUseID }
  func setInUse(_ id: AvatarID) async throws { try await library.setInUse(id) }
}

@MainActor
@Suite("The library of avatars, as the screens see it")
struct AvatarLibraryModelTests {
  nonisolated static let defaultAvatar = Sprites.set("Default", width: 1, source: .bundled)

  private func library(kept: [AvatarSpriteSet] = []) -> InMemoryAvatarLibrary {
    InMemoryAvatarLibrary(defaultAvatar: Self.defaultAvatar, kept: kept)
  }

  private func model(
    library: any AvatarLibrary, generator: ScriptedGenerator = ScriptedGenerator(),
    processing: FakeProcessing = FakeProcessing()
  ) async -> AvatarLibraryModel {
    let model = AvatarLibraryModel(
      workshop: AvatarWorkshop(processing: processing), library: library,
      generators: FakeGenerators(generator: generator))
    await model.load()
    await model.refreshOptions()
    return model
  }

  /// Waits for the generation under way to end, and what it brought back to be written.
  private func settle(_ model: AvatarLibraryModel) async {
    await model.task?.value
  }

  /// Generates an avatar from `description`, and waits for its draft.
  private func generated(
    _ model: AvatarLibraryModel, _ description: String = "a green frog"
  ) async throws -> AvatarID {
    model.description = description
    model.generate()
    await settle(model)
    return try #require(model.selectedID)
  }

  private func width(
    _ images: [AvatarExpression: NSImage], _ expression: AvatarExpression = .neutral
  ) -> CGFloat? {
    images[expression]?.size.width
  }

  // MARK: - Reading

  @Test("An empty library: the default avatar, in use, selected, in the panel")
  func empty() async {
    let model = await model(library: library())
    #expect(model.entries.map(\.id) == [.default])
    #expect(model.inUse == .default)
    #expect(model.selection == .avatar(.default))
    #expect(width(model.inUseImages) == 1)
    #expect(model.inUseProblem == nil)
    #expect(model.canCreate)
  }

  @Test("Only an agent that can draw is picked; the others say why")
  func options() async {
    let model = await model(library: library())
    #expect(model.selectedProvider == AgentProviderID("codex"))
    #expect(model.options.first?.unavailability == .notCapable)
  }

  @Test("Relaunched with a draft left: it is selected, not used")
  func draftLeftSelected() async throws {
    let library = library()
    let draft = try await library.saveDraft(Sprites.set("Fox", width: 4), basedOn: nil)
    let model = await model(library: library)
    #expect(model.selection == .avatar(draft))
    #expect(model.inUse == .default)
    #expect(width(model.selectedImages) == 4)
  }

  @Test("The avatar in use lacks expressions: the default one is shown, and what is missing said")
  func inUseIncomplete() async throws {
    let inner = library(kept: [Sprites.set("Old", width: 4, missing: [.thinking])])
    let old = try #require(try await inner.entries().last?.id)
    let model = await model(library: ForcedInUse(library: inner, inUseID: old))
    #expect(model.inUseProblem == .storedAvatar(missing: [.thinking]))
    #expect(width(model.inUseImages) == 1)
  }

  @Test("The avatar in use cannot be read: the default one is shown, and why")
  func inUseUnreadable() async throws {
    let inner = library(kept: [Sprites.set("Old", width: 4)])
    let old = try #require(try await inner.entries().last?.id)
    let model = await model(
      library: ForcedInUse(library: inner, inUseID: old, unreadable: true))
    #expect(model.inUseProblem == .storedAvatar(missing: []))
    #expect(width(model.inUseImages) == 1)
  }

  // MARK: - Generating

  @Test("A generation is listed while it runs, then written as a draft, selected; nothing is used")
  func generate() async throws {
    let generator = ScriptedGenerator()
    generator.hold()
    let library = library()
    let model = await model(library: library, generator: generator)
    model.description = "a green frog"
    #expect(model.canGenerate)
    let event = model.lastEvent
    model.generate()

    let work = try #require(model.work)
    #expect(work.kind == .wholeSet)
    #expect(work.description == "a green frog")
    #expect(model.selection == .job(work.id))
    #expect(model.description.isEmpty)
    #expect(!model.canStartCreation)
    #expect(try await library.entries().count == 1)

    generator.release()
    await settle(model)
    #expect(model.work == nil)
    #expect(model.jobs.isEmpty)
    let draft = try #require(model.entries.last)
    #expect(draft.state == .draft(basedOn: nil))
    #expect(draft.manifest?.description == "a green frog")
    #expect(draft.manifest?.provider == "codex")
    #expect(model.selection == .avatar(draft.id))
    #expect(width(model.selectedImages) == 2)
    #expect(model.inUse == .default)
    #expect(width(model.inUseImages) == 1)
    #expect(model.lastEvent != event)
  }

  @Test("A generation goes on with no screen, and its draft outlives the application")
  func outlivesTheScreen() async throws {
    let generator = ScriptedGenerator()
    generator.hold()
    let library = library()
    // The Settings window opens, starts a generation, and closes: only the model holds it.
    let model = await model(library: library, generator: generator)
    model.description = "a green frog"
    model.generate()
    generator.release()
    await settle(model)

    let drafts = try await library.entries().filter(\.isDraft)
    #expect(drafts.count == 1)
    // Relaunched: the library still holds the draft, selected, waiting to be kept.
    let relaunched = await self.model(library: library)
    #expect(relaunched.selection == .avatar(try #require(drafts.first).id))
    #expect(relaunched.entry(try #require(drafts.first).id)?.isDraft == true)
  }

  @Test("A generation that ends once the library is full is written all the same")
  func endsBeyondTheLimit() async throws {
    let kept = (1..<AvatarLibraryRules.maximumCount).map {
      Sprites.set("Kept \($0)", width: 4)
    }
    let generator = ScriptedGenerator()
    generator.hold()
    let library = library(kept: kept)
    let model = await model(library: library, generator: generator)
    #expect(model.canCreate)
    model.description = "a green frog"
    model.generate()
    // Meanwhile, another window fills the library.
    _ = try await library.duplicate(.default)
    generator.release()
    await settle(model)

    #expect(model.entries.count == AvatarLibraryRules.maximumCount + 2)
    #expect(model.entries.last?.isDraft == true)
    #expect(model.selectedID == model.entries.last?.id)
    #expect(!model.canCreate)
    model.description = "a red fox"
    #expect(!model.canGenerate)
    #expect(!model.canStartCreation)
  }

  @Test("A full library makes nothing new: no generation, no import, no copy")
  func fullLibrary() async throws {
    let kept = (0..<AvatarLibraryRules.maximumCount).map { Sprites.set("Kept \($0)", width: 4) }
    let library = library(kept: kept)
    let model = await model(
      library: library, processing: FakeProcessing(archived: Sprites.set("Fox", width: 4)))
    model.description = "a green frog"
    #expect(!model.canGenerate)
    model.generate()
    #expect(model.work == nil)

    await model.importArchive(Data("zip".utf8))
    #expect(model.problem == .limitReached)
    await model.duplicate(.default)
    #expect(model.problem == .limitReached)
    #expect(try await library.entries().count == AvatarLibraryRules.maximumCount + 1)
    #expect(
      Localization.string(AvatarPresentation.message(for: .limitReached), in: "fr")
        == "20 avatars au plus : supprimez-en un pour en créer un autre.")
  }

  @Test("One generation, or one import, at a time")
  func oneAtATime() async throws {
    let generator = ScriptedGenerator()
    generator.hold()
    let library = library()
    let model = await model(
      library: library, generator: generator,
      processing: FakeProcessing(archived: Sprites.set("Fox", width: 4)))
    model.description = "a green frog"
    model.generate()
    let first = try #require(model.work)
    model.description = "a red fox"
    #expect(!model.canGenerate)
    model.generate()
    await model.importArchive(Data("zip".utf8))
    #expect(model.jobs == [first])
    generator.release()
    await settle(model)
    #expect(try await library.entries().count == 2)
  }

  @Test("Cancelled: nothing is written, and the selection goes back to the avatar in use")
  func cancel() async throws {
    let generator = ScriptedGenerator()
    generator.hold()
    let library = library()
    let model = await model(library: library, generator: generator)
    model.description = "a green frog"
    model.generate()
    let task = model.task
    model.cancel()
    await task?.value

    #expect(model.jobs.isEmpty)
    #expect(model.problem == nil)
    #expect(model.selection == .avatar(.default))
    #expect(try await library.entries().count == 1)
  }

  @Test("A failed generation is listed with why, writes nothing, and can be tried again")
  func failureThenRetry() async throws {
    let generator = ScriptedGenerator([.failure(.timedOut)])
    let library = library()
    let model = await model(library: library, generator: generator)
    model.description = "a green frog"
    model.generate()
    await settle(model)

    let failure = try #require(model.failures.first)
    guard case .failed(.timedOut, _) = failure.phase else {
      Issue.record("Expected a timeout, got \(failure.phase)")
      return
    }
    #expect(model.selection == .job(failure.id))
    #expect(model.work == nil)
    #expect(model.canStartCreation)
    #expect(try await library.entries().count == 1)

    generator.answer(.success(Data("sheet".utf8)))
    model.retry(failure.id)
    #expect(model.work?.description == "a green frog")
    await settle(model)
    #expect(model.failures.isEmpty)
    #expect(model.entries.last?.manifest?.description == "a green frog")
    #expect(model.selectedID == model.entries.last?.id)
  }

  @Test("A failed generation is removed, or its description taken back to change it")
  func failureRemoved() async throws {
    let generator = ScriptedGenerator([.failure(.noImage)])
    let model = await model(library: library(), generator: generator)
    model.description = "a green frog"
    model.generate()
    await settle(model)
    await model.dismiss(try #require(model.failures.first).id)
    #expect(model.jobs.isEmpty)
    #expect(model.selection == .avatar(.default))

    model.description = "a red fox"
    model.generate()
    await settle(model)
    await model.reviseDescription(of: try #require(model.failures.first).id)
    #expect(model.jobs.isEmpty)
    #expect(model.description == "a red fox")
  }

  @Test("A sheet that is not the grid is refused with its problem")
  func rejected() async throws {
    let generator = ScriptedGenerator([.success(Data("other".utf8))])
    let model = await model(library: library(), generator: generator)
    model.description = "a frog"
    model.generate()
    await settle(model)
    let failure = try #require(model.failures.first)
    guard
      case .failed(
        .rejected(.wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1, height: 1)), _) =
        failure.phase
    else {
      Issue.record("Expected the wrong grid, got \(failure.phase)")
      return
    }
  }

  @Test("A generation cancelled that fails afterwards changes nothing")
  func cancelledThenFailed() async {
    let generator = ScriptedGenerator()
    generator.hold()
    let model = await model(library: library(), generator: generator)
    model.description = "a frog"
    model.generate()
    let old = model.task
    model.cancel()
    await old?.value
    #expect(model.problem == nil)
    #expect(model.jobs.isEmpty)
  }

  @Test("No description, no generation")
  func noDescription() async {
    let model = await model(library: library())
    model.description = "   "
    #expect(!model.canGenerate)
  }

  // MARK: - Keeping

  @Test("Kept, and used by default: the panel shows it at once")
  func keepAndUse() async throws {
    let model = await model(library: library())
    let draft = try await generated(model)
    #expect(model.usesKeptDraft)
    #expect(model.canKeep(draft))
    await model.keep(draft)

    #expect(model.entry(draft)?.state == .kept)
    #expect(model.inUse == draft)
    #expect(width(model.inUseImages) == 2)
    #expect(model.selection == .avatar(draft))
  }

  @Test("Kept without using it: the panel keeps its avatar")
  func keepOnly() async throws {
    let model = await model(library: library())
    let draft = try await generated(model)
    model.usesKeptDraft = false
    await model.keep(draft)
    #expect(model.entry(draft)?.state == .kept)
    #expect(model.inUse == .default)
    #expect(width(model.inUseImages) == 1)
  }

  @Test("Discarded: the draft is gone, the selection back on the avatar in use")
  func discard() async throws {
    let library = library()
    let model = await model(library: library)
    let draft = try await generated(model)
    await model.discard(draft)
    #expect(model.entry(draft) == nil)
    #expect(model.selection == .avatar(.default))
    #expect(try await library.entries().count == 1)
  }

  @Test("Drawn again whole: the draft keeps its place and its name")
  func regenerateAll() async throws {
    let generator = ScriptedGenerator()
    let model = await model(library: library(), generator: generator)
    let draft = try await generated(model)
    await model.rename(draft, to: "Froggy")
    model.regenerateAll(draft)
    #expect(model.work?.avatar == draft)
    #expect(!model.canKeep(draft))
    await settle(model)
    #expect(model.entries.count == 2)
    #expect(model.entry(draft)?.manifest?.name == "Froggy")
    #expect(model.selection == .avatar(draft))
  }

  // MARK: - Redrawing and completing

  @Test("An incomplete archive: a draft that cannot be kept until completed, where it is")
  func incompleteImport() async throws {
    let partial = Sprites.set("", width: 4, missing: [.thinking])
    let library = library()
    let model = await model(library: library, processing: FakeProcessing(archived: partial))
    await model.importArchive(Data("zip".utf8))

    let draft = try #require(model.selectedID)
    #expect(model.entry(draft)?.isDraft == true)
    #expect(model.selectedAvatar?.missingExpressions == [.thinking])
    #expect(model.entry(draft).map(AvatarLibraryModel.name) == "Imported avatar")
    #expect(model.ignoredFiles?.draft == draft)
    #expect(model.ignoredFiles?.count == 2)
    #expect(!model.canKeep(draft))
    await model.keep(draft)
    #expect(model.entry(draft)?.isDraft == true)

    model.regenerate(.thinking)
    #expect(model.work?.kind == .expression(.thinking))
    await settle(model)
    #expect(model.entries.count == 2)
    #expect(model.selection == .avatar(draft))
    #expect(width(model.selectedImages, .thinking) == 3)
    #expect(width(model.selectedImages, .neutral) == 4)
    await model.keep(draft)
    #expect(model.inUse == draft)
  }

  @Test("An archive is always a draft, never written over the avatar in use")
  func importIsADraft() async throws {
    let fox = Sprites.set("Fox", width: 4)
    let library = library(kept: [Sprites.set("Mine", width: 2)])
    let mine = try #require(try await library.entries().last?.id)
    try await library.setInUse(mine)
    let model = await model(library: library, processing: FakeProcessing(archived: fox))
    await model.importArchive(Data("zip".utf8))
    #expect(model.entries.count == 3)
    #expect(model.entries.last?.isDraft == true)
    #expect(model.inUse == mine)
  }

  @Test("An expression of a kept avatar drawn again: a linked draft, which replaces it once kept")
  func redrawKept() async throws {
    let fox = Sprites.set("Fox", width: 4, description: "a red fox")
    let library = library(kept: [fox])
    let kept = try #require(try await library.entries().last?.id)
    try await library.setInUse(kept)
    let model = await model(library: library)
    await model.select(.avatar(kept))
    #expect(model.canRegenerate)

    model.regenerate(.eyesClosed)
    await settle(model)
    let draft = try #require(model.selectedID)
    #expect(draft != kept)
    #expect(model.entry(draft)?.state == .draft(basedOn: kept))
    #expect(width(model.inUseImages, .eyesClosed) == 4)

    // Once more, from the original: the same draft changes, no second one is made.
    await model.select(.avatar(kept))
    model.regenerate(.pleased)
    await settle(model)
    #expect(model.selectedID == draft)
    #expect(model.entries.filter(\.isDraft).count == 1)
    #expect(width(model.selectedImages, .eyesClosed) == 3)
    #expect(width(model.selectedImages, .pleased) == 3)

    model.usesKeptDraft = false
    await model.keep(draft)
    #expect(model.entry(draft) == nil)
    #expect(model.selection == .avatar(kept))
    #expect(model.inUse == kept)
    #expect(width(model.inUseImages, .eyesClosed) == 3)
    #expect(width(model.inUseImages, .neutral) == 4)
  }

  @Test("A redrawing that fails leaves the avatar as it was, and says why")
  func redrawFails() async throws {
    let generator = ScriptedGenerator()
    let model = await model(library: library(), generator: generator)
    let draft = try await generated(model)
    generator.answer(.failure(.noImage))
    model.regenerate(.worried)
    await settle(model)
    #expect(model.problem == .generation(.noImage))
    #expect(model.failures.isEmpty)
    #expect(model.selection == .avatar(draft))
    #expect(width(model.selectedImages, .worried) == 2)
  }

  @Test("The default avatar, and a kept one with no description, are not redrawn")
  func notRedrawn() async throws {
    let library = library(kept: [Sprites.set("Plain", width: 4)])
    let plain = try #require(try await library.entries().last?.id)
    let model = await model(library: library)
    #expect(model.selection == .avatar(.default))
    #expect(!model.canRegenerate)
    await model.select(.avatar(plain))
    #expect(!model.canRegenerate)
  }

  @Test("A kept avatar lacking expressions is completed through a draft")
  func completeKept() async throws {
    let library = library(kept: [Sprites.set("Old", width: 4, missing: [.worried])])
    let old = try #require(try await library.entries().last?.id)
    let model = await model(library: library)
    await model.select(.avatar(old))
    #expect(model.canRegenerate)
    await model.completeDraft(of: old)
    let draft = try #require(model.selectedID)
    #expect(model.entry(draft)?.state == .draft(basedOn: old))
    model.regenerate(.worried)
    await settle(model)
    #expect(model.selectedID == draft)
    await model.keep(draft)
    #expect(model.inUse == old)
    #expect(width(model.inUseImages, .worried) == 3)
    #expect(model.inUseProblem == nil)
  }

  // MARK: - Using, renaming, copying, deleting

  @Test("The panel follows the avatar in use: used, deleted, back to the default")
  func inUseImagesFollow() async throws {
    let library = library(kept: [Sprites.set("Fox", width: 4)])
    let fox = try #require(try await library.entries().last?.id)
    let model = await model(library: library)
    await model.use(fox)
    #expect(model.inUse == fox)
    #expect(width(model.inUseImages) == 4)
    await model.use(.default)
    #expect(width(model.inUseImages) == 1)
    await model.use(fox)
    await model.remove(fox)
    #expect(model.inUse == .default)
    #expect(width(model.inUseImages) == 1)
    #expect(model.entry(fox) == nil)
    #expect(model.selection == .avatar(.default))
  }

  @Test("A draft is not used; the default avatar is not renamed or deleted")
  func refusals() async throws {
    let model = await model(library: library())
    let draft = try await generated(model)
    await model.use(draft)
    #expect(model.problem == .saving)
    #expect(model.inUse == .default)
    await model.rename(.default, to: "Mine")
    #expect(model.problem == .saving)
    await model.remove(.default)
    #expect(model.entries.count == 2)
  }

  @Test("Renamed, and copied: the copy is kept, selected, named after the original")
  func renameAndDuplicate() async throws {
    let library = library(kept: [Sprites.set("Fox", width: 4)])
    let fox = try #require(try await library.entries().last?.id)
    let model = await model(library: library)
    await model.rename(fox, to: "  Renard  ")
    #expect(model.entry(fox)?.manifest?.name == "Renard")
    await model.duplicate(fox)
    let copy = try #require(model.selectedID)
    #expect(copy != fox)
    #expect(model.entry(copy)?.state == .kept)
    #expect(model.entry(copy)?.manifest?.name == "Renard (copy)")
  }

  @Test("Deleting an avatar being redrawn stops the redrawing first")
  func removeWhileRedrawn() async throws {
    let generator = ScriptedGenerator()
    let library = library()
    let model = await model(library: library, generator: generator)
    let draft = try await generated(model)
    generator.hold()
    model.regenerate(.worried)
    let task = model.task
    await model.discard(draft)
    await task?.value
    #expect(model.jobs.isEmpty)
    #expect(try await library.entries().count == 1)
  }

  // MARK: - Archives

  @Test("An archive that cannot be read says why; nothing changes")
  func unreadableImport() async throws {
    let library = library()
    let model = await model(library: library)
    await model.importArchive(Data("zip".utf8))
    #expect(model.problem == .archive(.archiveUnreadable))
    #expect(try await library.entries().count == 1)
  }

  @Test("Exported: the default avatar too, with or without its description")
  func export() async throws {
    let library = library(kept: [Sprites.set("Fox", width: 4, description: "a red fox")])
    let fox = try #require(try await library.entries().last?.id)
    let model = await model(library: library)
    #expect(model.exportFileName(.default) == "Avatar - Default Avatar")
    #expect(
      await model.exportArchive(.default, includingDescription: true) == Data("Default|".utf8))
    #expect(model.exportFileName(fox) == "Avatar - Fox")
    #expect(
      await model.exportArchive(fox, includingDescription: true) == Data("Fox|a red fox".utf8))
    #expect(await model.exportArchive(fox, includingDescription: false) == Data("Fox|".utf8))
  }

  @Test("The names of the expressions and the problems read in French")
  func french() {
    #expect(
      Localization.string(AvatarPresentation.name(of: .mouthRound), in: "fr") == "Bouche en « O »")
    #expect(
      Localization.string(AvatarPresentation.reason(.notCapable), in: "fr")
        == "ne produit pas d’images")
    #expect(
      Localization.string(
        AvatarPresentation.message(for: .archive(.archiveEncrypted)), in: "fr")
        == "L’archive est chiffrée.")
  }
}
