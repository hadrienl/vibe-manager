import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

/// Images that need no decoding: each sprite is the name of its expression.
private struct FakeProcessing: AvatarImageProcessing {
  var archived: AvatarSpriteSet?

  func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  {
    guard data == Data("sheet".utf8) else {
      throw AvatarProblem.wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1, height: 1)
    }
    return Dictionary(uniqueKeysWithValues: expressions.map { ($0, Data($0.rawValue.utf8)) })
  }

  func sprite(fromImage data: Data, as expression: AvatarExpression, matching reference: Data?)
    throws -> Data
  {
    Data("new \(expression.rawValue)".utf8)
  }

  func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int) {
    guard let archived else { throw AvatarProblem.archiveUnreadable }
    return (archived, 2)
  }

  func archive(_ avatar: AvatarSpriteSet) throws -> Data {
    Data(avatar.manifest.name.utf8)
  }
}

private struct FakeGenerator: AvatarGenerating {
  var answer: Result<Data, AvatarGenerationError> = .success(Data("sheet".utf8))

  func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    try answer.get()
  }
}

private struct FakeGenerators: AvatarGeneratorResolving {
  var generator: FakeGenerator

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

@MainActor
@Suite("Making an avatar")
struct AvatarStudioTests {
  nonisolated static let defaultAvatar = AvatarSpriteSet(
    manifest: AvatarManifest(name: "Default", source: .bundled),
    sprites: Dictionary(
      uniqueKeysWithValues: AvatarExpression.allCases.map { ($0, Data("default".utf8)) }))

  private func studio(
    store: any AvatarStore = InMemoryAvatarStore(), generator: FakeGenerator = FakeGenerator(),
    processing: FakeProcessing = FakeProcessing()
  ) -> AvatarStudioModel {
    AvatarStudioModel(
      workshop: AvatarWorkshop(processing: processing), store: store,
      generators: FakeGenerators(generator: generator),
      defaultAvatar: { AvatarStudioTests.defaultAvatar })
  }

  /// Waits for the generation under way to end.
  private func settle(_ studio: AvatarStudioModel) async {
    await studio.task?.value
  }

  @Test("Nothing kept: the default avatar")
  func defaultAvatar() async {
    let studio = studio()
    await studio.load()
    #expect(studio.current?.manifest.name == "Default")
    #expect(!studio.isCustom)
  }

  @Test("Only an agent that can draw is picked; the others say why")
  func options() async {
    let studio = studio()
    await studio.refreshOptions()
    #expect(studio.selectedProvider == AgentProviderID("codex"))
    #expect(studio.options.first?.unavailability == .notCapable)
  }

  @Test("A generation makes a candidate; the avatar in use changes only once it is used")
  func generateThenAccept() async throws {
    let store = InMemoryAvatarStore()
    let studio = studio(store: store)
    await studio.load()
    await studio.refreshOptions()
    studio.description = "a green frog"
    #expect(studio.canGenerate)
    studio.generate()
    #expect(studio.work?.kind == .wholeSet)
    await settle(studio)

    let candidate = try #require(studio.candidate)
    #expect(candidate.isComplete)
    #expect(candidate.manifest.description == "a green frog")
    #expect(candidate.manifest.provider == "codex")
    #expect(studio.current?.manifest.name == "Default")

    await studio.accept()
    #expect(studio.isCustom)
    #expect(studio.candidate == nil)
    #expect(try await store.load()?.manifest.description == "a green frog")
  }

  @Test("No description, no generation")
  func noDescription() async {
    let studio = studio()
    await studio.refreshOptions()
    studio.description = "   "
    #expect(!studio.canGenerate)
  }

  @Test("A failed generation says why, and changes nothing")
  func failure() async {
    let studio = studio(generator: FakeGenerator(answer: .failure(.timedOut)))
    await studio.load()
    await studio.refreshOptions()
    studio.description = "a frog"
    studio.generate()
    await settle(studio)
    #expect(studio.problem == .generation(.timedOut))
    #expect(studio.candidate == nil)
    #expect(studio.current?.manifest.name == "Default")
  }

  @Test("A sheet that is not the grid is refused with its problem")
  func rejected() async {
    let studio = studio(generator: FakeGenerator(answer: .success(Data("other".utf8))))
    await studio.refreshOptions()
    studio.description = "a frog"
    studio.generate()
    await settle(studio)
    #expect(
      studio.problem
        == .generation(
          .rejected(.wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1, height: 1))))
  }

  @Test("One expression is drawn again, the others kept")
  func regenerate() async throws {
    let studio = studio()
    await studio.refreshOptions()
    studio.description = "a frog"
    studio.generate()
    await settle(studio)
    studio.regenerate(.eyesClosed)
    #expect(studio.work?.kind == .expression(.eyesClosed))
    await settle(studio)
    let candidate = try #require(studio.candidate)
    #expect(candidate.sprites[.eyesClosed] == Data("new eyesClosed".utf8))
    #expect(candidate.sprites[.neutral] == Data("neutral".utf8))
  }

  @Test("An incomplete archive becomes a candidate that cannot be used until completed")
  func incompleteImport() async throws {
    var partial = AvatarStudioTests.defaultAvatar
    partial.manifest = AvatarManifest(name: "", source: .imported)
    partial.sprites[.thinking] = nil
    let studio = studio(processing: FakeProcessing(archived: partial))
    await studio.load()
    studio.importArchive(Data("zip".utf8))

    let candidate = try #require(studio.candidate)
    #expect(candidate.missingExpressions == [.thinking])
    #expect(!candidate.manifest.name.isEmpty)
    #expect(studio.ignoredFiles == 2)
    await studio.accept()
    #expect(!studio.isCustom)
    #expect(studio.candidate != nil)

    await studio.refreshOptions()
    studio.regenerate(.thinking)
    await settle(studio)
    #expect(studio.candidate?.isComplete == true)
    await studio.accept()
    #expect(studio.isCustom)
  }

  @Test("An archive that cannot be read says why; nothing changes")
  func unreadableImport() async {
    let studio = studio()
    await studio.load()
    studio.importArchive(Data("zip".utf8))
    #expect(studio.problem == .archive(.archiveUnreadable))
    #expect(studio.candidate == nil)
  }

  @Test("Back to the default: the kept avatar is removed")
  func reset() async throws {
    let store = InMemoryAvatarStore(AvatarStudioTests.defaultAvatar)
    let studio = studio(store: store)
    await studio.load()
    #expect(studio.isCustom)
    await studio.resetToDefault()
    #expect(!studio.isCustom)
    #expect(try await store.load() == nil)
  }

  @Test("A kept avatar lacking expressions: the default is shown, and the missing ones named")
  func storedIncomplete() async {
    let studio = studio(store: IncompleteStore())
    await studio.load()
    #expect(studio.problem == .storedAvatar(missing: [.thinking]))
    #expect(!studio.isCustom)
    #expect(studio.current?.manifest.name == "Default")
  }

  @Test("The export's file name, and the default avatar exported too")
  func export() async {
    let studio = studio()
    await studio.load()
    #expect(studio.exportFileName == "Avatar - Default")
    #expect(studio.exportArchive(includingDescription: true) == Data("Default".utf8))
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

private struct IncompleteStore: AvatarStore {
  func load() async throws -> AvatarSpriteSet? { throw AvatarStoreError.incomplete([.thinking]) }
  func save(_ avatar: AvatarSpriteSet) async throws {}
  func remove() async throws {}
}
