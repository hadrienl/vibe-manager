import Foundation
import Testing
import VibeLocalizationTesting

@testable import VibeApplication

@Suite("The library of avatars: its rules")
struct AvatarLibraryRulesTests {
  static func avatar(
    _ name: String, missing: Set<AvatarExpression> = [], marker: UInt8 = 1
  ) -> AvatarSpriteSet {
    var sprites: [AvatarExpression: Data] = [:]
    for expression in AvatarExpression.allCases where !missing.contains(expression) {
      sprites[expression] = Data([marker])
    }
    return AvatarSpriteSet(
      manifest: AvatarManifest(name: name, source: .generated, description: "A \(name)"),
      sprites: sprites)
  }

  /// A clock that moves a second at every reading: every avatar enters at its own instant.
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date {
      lock.withLock {
        instant += 1
        return instant
      }
    }
  }

  static func library(defaultAvatar: AvatarSpriteSet? = avatar("Placeholder"))
    -> InMemoryAvatarLibrary
  {
    let clock = Clock()
    return InMemoryAvatarLibrary(defaultAvatar: defaultAvatar, now: { clock.now() })
  }

  @Test("An identifier reads back as it was written: default, or a UUID")
  func identifiers() throws {
    let uuid = UUID()
    #expect(AvatarID("default") == .default)
    #expect(AvatarID(uuid.uuidString) == .stored(uuid))
    #expect(AvatarID("Avatar") == nil)
    let encoded = try JSONEncoder().encode([AvatarID.default, .stored(uuid)])
    #expect(String(decoding: encoded, as: UTF8.self) == "[\"default\",\"\(uuid.uuidString)\"]")
    #expect(try JSONDecoder().decode([AvatarID].self, from: encoded) == [.default, .stored(uuid)])
  }

  @Test("The default avatar first, then the others in the order they entered, whatever their names")
  func order() {
    let first = UUID()
    let second = UUID()
    let entries = [
      AvatarLibraryEntry(
        id: .stored(second), state: .draft(basedOn: nil), manifest: nil,
        addedAt: Date(timeIntervalSince1970: 20)),
      AvatarLibraryEntry(
        id: .stored(first), state: .kept, manifest: nil, addedAt: Date(timeIntervalSince1970: 10)),
      AvatarLibraryEntry(id: .default, state: .kept, manifest: nil, addedAt: .distantFuture),
    ]
    #expect(
      AvatarLibraryRules.ordered(entries).map(\.id) == [.default, .stored(first), .stored(second)])
  }

  @Test("A name keeps its first line, trimmed, and at most 60 characters; blank is no name")
  func names() {
    #expect(AvatarLibraryRules.name("  Renard roux  \nà écharpe") == "Renard roux")
    #expect(AvatarLibraryRules.name("\n\n  Robot") == "Robot")
    #expect(AvatarLibraryRules.name(String(repeating: "a", count: 80))?.count == 60)
    #expect(AvatarLibraryRules.name(" \n\t ") == nil)
  }

  @Test("A copy is named after its original, in the user's language, within 60 characters")
  func copyNames() {
    #expect(AvatarLibraryRules.copyName(of: "Renard") == "Renard (copy)")
    #expect(
      Localization.string("\("Renard") (copy)", module: "VibeApplication", in: "fr")
        == "Renard (copie)")
    #expect(
      Localization.string("Default Avatar", module: "VibeApplication", in: "fr")
        == "Avatar par défaut")
    let long = AvatarLibraryRules.copyName(of: String(repeating: "b", count: 60))
    #expect(long.count == AvatarManifest.maximumNameLength)
    #expect(long.hasSuffix("b (copy)"))
  }

  @Test("20 avatars at most, drafts included: the 21st is refused and nothing changes")
  func limit() throws {
    var index = AvatarLibraryIndex()
    for number in 0..<AvatarLibraryRules.maximumCount {
      let state: AvatarLibraryEntry.State = number.isMultiple(of: 2) ? .kept : .draft(basedOn: nil)
      try index.add(UUID(), as: state, at: Date(timeIntervalSince1970: Double(number)))
    }
    #expect(!index.hasRoom)
    let before = index
    #expect(throws: AvatarLibraryError.limitReached) {
      try index.add(UUID(), as: .draft(basedOn: nil), at: .now)
    }
    #expect(index == before)
  }

  @Test("Deleting the avatar in use gives the panel back the default one")
  func removeInUse() throws {
    let id = UUID()
    var index = AvatarLibraryIndex()
    try index.add(id, as: .kept, at: .now)
    try index.setInUse(.stored(id))
    try index.remove(.stored(id))
    #expect(index.inUse == .default)
    #expect(index.records.isEmpty)
  }

  @Test("The default avatar is not deleted, renamed or kept as a draft")
  func defaultIsFixed() async throws {
    var index = AvatarLibraryIndex()
    #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) { try index.remove(.default) }
    #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) {
      _ = try index.keep(.default, missing: [])
    }
    let library = Self.library()
    await #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) {
      try await library.rename(.default, to: "Mine")
    }
    await #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) {
      try await library.remove(.default)
    }
  }

  @Test("A draft is not used before it is kept, and an index read from disk cannot say otherwise")
  func draftNotUsed() throws {
    let id = UUID()
    var index = AvatarLibraryIndex()
    try index.add(id, as: .draft(basedOn: nil), at: .now)
    #expect(throws: AvatarLibraryError.notKept) { try index.setInUse(.stored(id)) }
    let read = AvatarLibraryIndex(
      inUse: .stored(id), records: [.init(id: id, state: .draft(basedOn: nil), addedAt: .now)])
    #expect(read.inUse == .default)
    let orphan = AvatarLibraryIndex(inUse: .stored(UUID()), records: [])
    #expect(orphan.inUse == .default)
  }

  @Test("A draft is kept only complete")
  func keepIncomplete() async throws {
    let library = Self.library()
    let draft = try await library.saveDraft(
      Self.avatar("Robot", missing: [.worried, .thinking]), basedOn: nil)
    await #expect(throws: AvatarLibraryError.incomplete([.thinking, .worried])) {
      _ = try await library.keep(draft)
    }
    #expect(try await library.entries().last?.state == .draft(basedOn: nil))
  }

  @Test("Made, a draft is listed last; kept, then used, it is what the panel shows")
  func keepThenUse() async throws {
    let library = Self.library()
    let fox = try await library.duplicate(.default)
    let robot = try await library.saveDraft(Self.avatar("Robot"), basedOn: nil)
    #expect(try await library.entries().map(\.id) == [.default, fox, robot])
    #expect(try await library.entries().last?.isDraft == true)

    #expect(try await library.keep(robot) == robot)
    #expect(try await library.inUse() == .default)
    try await library.setInUse(robot)
    #expect(try await library.inUse() == robot)
    #expect(try await library.load(robot).manifest.name == "Robot")
    await #expect(throws: AvatarLibraryError.notADraft) { _ = try await library.keep(robot) }
  }

  @Test("A kept avatar redrawn: its draft replaces it once kept, under the same identifier, in use")
  func redrawnKept() async throws {
    let library = Self.library()
    let robot = try await library.saveDraft(Self.avatar("Robot", marker: 1), basedOn: nil)
    _ = try await library.keep(robot)
    try await library.setInUse(robot)

    let draft = try await library.saveDraft(Self.avatar("Robot", marker: 2), basedOn: robot)
    #expect(try await library.entries().count == 3)
    #expect(try await library.load(robot).sprites[.neutral] == Data([1]))

    #expect(try await library.keep(draft) == robot)
    #expect(try await library.entries().map(\.id) == [.default, robot])
    #expect(try await library.load(robot).sprites[.neutral] == Data([2]))
    #expect(try await library.inUse() == robot)
    await #expect(throws: AvatarLibraryError.notFound) { _ = try await library.load(draft) }
  }

  @Test("A draft whose original was deleted meanwhile becomes a draft of its own")
  func orphanDraft() async throws {
    let library = Self.library()
    let robot = try await library.saveDraft(Self.avatar("Robot"), basedOn: nil)
    _ = try await library.keep(robot)
    let draft = try await library.saveDraft(Self.avatar("Robot"), basedOn: robot)
    try await library.remove(robot)
    #expect(try await library.entries().last?.state == .draft(basedOn: nil))
    #expect(try await library.keep(draft) == draft)
  }

  @Test("A draft is only based on a kept avatar")
  func basedOnKeptOnly() async throws {
    let library = Self.library()
    let draft = try await library.saveDraft(Self.avatar("Robot"), basedOn: nil)
    await #expect(throws: AvatarLibraryError.notFound) {
      _ = try await library.saveDraft(Self.avatar("Robot"), basedOn: draft)
    }
    await #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) {
      _ = try await library.saveDraft(Self.avatar("Robot"), basedOn: .default)
    }
  }

  @Test("A draft's images are replaced where it is; a kept avatar's are not")
  func updateDraft() async throws {
    let library = Self.library()
    let draft = try await library.saveDraft(Self.avatar("Robot", marker: 1), basedOn: nil)
    try await library.updateDraft(draft, with: Self.avatar("Robot", marker: 3))
    #expect(try await library.load(draft).sprites[.neutral] == Data([3]))
    _ = try await library.keep(draft)
    await #expect(throws: AvatarLibraryError.notADraft) {
      try await library.updateDraft(draft, with: Self.avatar("Robot"))
    }
  }

  @Test("Renamed: the name is cleaned; blank is refused")
  func rename() async throws {
    let library = Self.library()
    let robot = try await library.saveDraft(Self.avatar("Robot"), basedOn: nil)
    try await library.rename(robot, to: "  Robot rétro menthe \n")
    #expect(try await library.load(robot).manifest.name == "Robot rétro menthe")
    await #expect(throws: AvatarLibraryError.emptyName) { try await library.rename(robot, to: " ") }
    await #expect(throws: AvatarLibraryError.notFound) {
      try await library.rename(.stored(UUID()), to: "Robot")
    }
  }

  @Test("The default avatar duplicated: a kept, imported copy of it, named after it")
  func duplicateDefault() async throws {
    let library = Self.library()
    let copy = try await library.duplicate(.default)
    let avatar = try await library.load(copy)
    #expect(avatar.manifest.name == "Default Avatar (copy)")
    #expect(avatar.manifest.source == .imported)
    #expect(avatar.sprites == (try await library.load(.default)).sprites)
    #expect(try await library.entries().last?.state == .kept)
  }

  @Test("At the limit, neither a draft nor a copy is added")
  func libraryLimit() async throws {
    let library = Self.library()
    for _ in 0..<AvatarLibraryRules.maximumCount {
      _ = try await library.saveDraft(Self.avatar("Robot"), basedOn: nil)
    }
    await #expect(throws: AvatarLibraryError.limitReached) {
      _ = try await library.saveDraft(Self.avatar("Robot"), basedOn: nil)
    }
    await #expect(throws: AvatarLibraryError.limitReached) {
      _ = try await library.duplicate(.default)
    }
    #expect(try await library.entries().count == AvatarLibraryRules.maximumCount + 1)
  }

  @Test("Without the default avatar, its entry says why, and nothing else breaks")
  func missingDefault() async throws {
    let library = Self.library(defaultAvatar: nil)
    #expect(try await library.entries().first?.problem == .unreadable)
    await #expect(throws: AvatarStoreError.unreadable) { _ = try await library.load(.default) }
    #expect(try await library.inUse() == .default)
  }

  @Test("Each entry says what it takes")
  func sizes() async throws {
    let library = Self.library()
    var avatar = Self.avatar("Robot")
    avatar.sheet = Data(count: 100)
    let robot = try await library.saveDraft(avatar, basedOn: nil)
    let entry = try #require(try await library.entries().first { $0.id == robot })
    #expect(entry.byteCount == Int64(AvatarExpression.allCases.count + 100))
  }
}
