import Foundation
import VibeApplication

/// What every `AvatarLibrary` does, whatever keeps it (#154): the same cases run against the one in
/// memory and the one on disk. Each case throws `AvatarLibraryContract.Failure` when the library
/// does not do what it says.
public struct AvatarLibraryContract: Sendable {
  /// A library holding `kept` — avatars already kept, as a library read from disk would hold them,
  /// even incomplete — beside `defaultAvatar`, whose clock is `now`.
  public typealias Factory =
    @Sendable (
      _ defaultAvatar: AvatarSpriteSet?, _ kept: [AvatarSpriteSet],
      _ now: @escaping @Sendable () -> Date
    ) async throws -> any AvatarLibrary

  public struct Failure: Error, CustomStringConvertible {
    public let description: String
  }

  public enum Case: String, CaseIterable, Sendable {
    case defaultIsFixed = "The default avatar is not renamed or deleted"
    case keepIncomplete = "A draft is kept only complete"
    case keepThenUse = "Made, a draft is listed last; kept, then used, it is what the panel shows"
    case redrawnKept =
      "A kept avatar redrawn: its draft replaces it once kept, under the same identifier, in use"
    case orphanDraft = "A draft whose original was deleted meanwhile becomes a draft of its own"
    case basedOnKeptOnly = "A draft is only based on a kept avatar"
    case updateDraft = "A draft's images are replaced where it is; a kept avatar's are not"
    case rename = "Renamed: the name is cleaned; blank is refused"
    case duplicateDefault = "The default avatar duplicated: a kept, imported copy, named after it"
    case libraryLimit =
      "At the limit, no copy is made, and a generation that ends there is still written"
    case redrawAtLimit = "At the limit, a kept avatar can still be redrawn: its draft replaces it"
    case missingDefault = "Without the default avatar, its entry says why, and nothing else breaks"
    case sizes = "Each entry says what it takes"
    case redrawKeepsName =
      "Kept, a redrawing draft brings its images and description, not the name it was given"
    case incompleteKept =
      "A kept avatar that lacks expressions: listed with why, read partly, completed by a draft"
    case draftNotCopied = "A draft is neither copied nor used"
    case discardKeepsUse = "Discarding a draft leaves the avatar in use alone"
    case useUnknown = "Using or reading an avatar the library does not hold is refused"
    case removeInUse = "Deleting the avatar in use: the default one is back in use"
  }

  private let make: Factory
  private let sprite: @Sendable (UInt8) -> Data

  /// - Parameters:
  ///   - sprite: a sprite the library accepts, told apart from the others by its marker.
  public init(sprite: @escaping @Sendable (UInt8) -> Data, make: @escaping Factory) {
    self.sprite = sprite
    self.make = make
  }

  /// An avatar whose sprites all carry `marker`.
  public func avatar(
    _ name: String, missing: Set<AvatarExpression> = [], marker: UInt8 = 1
  ) -> AvatarSpriteSet {
    var sprites: [AvatarExpression: Data] = [:]
    for expression in AvatarExpression.allCases where !missing.contains(expression) {
      sprites[expression] = sprite(marker)
    }
    return AvatarSpriteSet(
      manifest: AvatarManifest(name: name, source: .generated, description: "A \(name)"),
      sprites: sprites)
  }

  /// A clock that moves a second at every reading: every avatar enters at its own instant.
  public final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000_000)

    public init() {}

    public func now() -> Date {
      lock.withLock {
        instant += 1
        return instant
      }
    }
  }

  private func library(
    defaultAvatar: AvatarSpriteSet?? = nil, kept: [AvatarSpriteSet] = []
  ) async throws -> any AvatarLibrary {
    let clock = Clock()
    return try await make(defaultAvatar ?? avatar("Placeholder"), kept, { clock.now() })
  }

  // MARK: - Checking

  private func check(
    _ condition: Bool, _ what: @autoclosure () -> String, line: Int = #line
  ) throws {
    guard condition else { throw Failure(description: "line \(line): \(what())") }
  }

  private func expect<E: Error & Equatable>(
    _ expected: E, line: Int = #line, _ body: () async throws -> Void
  ) async throws {
    do {
      try await body()
    } catch let error as E where error == expected {
      return
    } catch {
      throw Failure(description: "line \(line): expected \(expected), got \(error)")
    }
    throw Failure(description: "line \(line): expected \(expected), nothing was thrown")
  }

  // MARK: - Cases

  public func run(_ contractCase: Case) async throws {
    switch contractCase {
    case .defaultIsFixed: try await defaultIsFixed()
    case .keepIncomplete: try await keepIncomplete()
    case .keepThenUse: try await keepThenUse()
    case .redrawnKept: try await redrawnKept()
    case .orphanDraft: try await orphanDraft()
    case .basedOnKeptOnly: try await basedOnKeptOnly()
    case .updateDraft: try await updateDraft()
    case .rename: try await rename()
    case .duplicateDefault: try await duplicateDefault()
    case .libraryLimit: try await libraryLimit()
    case .redrawAtLimit: try await redrawAtLimit()
    case .missingDefault: try await missingDefault()
    case .sizes: try await sizes()
    case .redrawKeepsName: try await redrawKeepsName()
    case .incompleteKept: try await incompleteKept()
    case .draftNotCopied: try await draftNotCopied()
    case .discardKeepsUse: try await discardKeepsUse()
    case .useUnknown: try await useUnknown()
    case .removeInUse: try await removeInUse()
    }
  }

  private func defaultIsFixed() async throws {
    let library = try await library()
    try await expect(AvatarLibraryError.defaultAvatarIsFixed) {
      try await library.rename(.default, to: "Mine")
    }
    try await expect(AvatarLibraryError.defaultAvatarIsFixed) { try await library.remove(.default) }
    try await expect(AvatarLibraryError.defaultAvatarIsFixed) {
      _ = try await library.keep(.default)
    }
  }

  private func keepIncomplete() async throws {
    let library = try await library()
    let draft = try await library.saveDraft(
      avatar("Robot", missing: [.worried, .thinking]), basedOn: nil)
    try await expect(AvatarLibraryError.incomplete([.thinking, .worried])) {
      _ = try await library.keep(draft)
    }
    try check(
      try await library.entries().last?.state == .draft(basedOn: nil), "still a draft")
  }

  private func keepThenUse() async throws {
    let library = try await library()
    let fox = try await library.duplicate(.default)
    let robot = try await library.saveDraft(avatar("Robot"), basedOn: nil)
    try check(try await library.entries().map(\.id) == [.default, fox, robot], "order")
    try check(try await library.entries().last?.isDraft == true, "a draft")

    try check(try await library.keep(robot) == robot, "kept where it is")
    try check(try await library.inUse() == .default, "kept is not used")
    try await library.setInUse(robot)
    try check(try await library.inUse() == robot, "used")
    try check(try await library.load(robot).manifest.name == "Robot", "name")
    try await expect(AvatarLibraryError.notADraft) { _ = try await library.keep(robot) }
  }

  private func redrawnKept() async throws {
    let library = try await library()
    let robot = try await library.saveDraft(avatar("Robot", marker: 1), basedOn: nil)
    _ = try await library.keep(robot)
    try await library.setInUse(robot)

    let draft = try await library.saveDraft(avatar("Robot", marker: 2), basedOn: robot)
    try check(try await library.entries().count == 3, "the draft beside its original")
    try check(try await library.load(robot).sprites[.neutral] == sprite(1), "original untouched")

    try check(try await library.keep(draft) == robot, "the original kept")
    try check(try await library.entries().map(\.id) == [.default, robot], "the draft gone")
    try check(try await library.load(robot).sprites[.neutral] == sprite(2), "images replaced")
    try check(try await library.inUse() == robot, "still in use")
    try await expect(AvatarLibraryError.notFound) { _ = try await library.load(draft) }
  }

  private func orphanDraft() async throws {
    let library = try await library()
    let robot = try await library.saveDraft(avatar("Robot"), basedOn: nil)
    _ = try await library.keep(robot)
    let draft = try await library.saveDraft(avatar("Robot"), basedOn: robot)
    try await library.remove(robot)
    try check(try await library.entries().last?.state == .draft(basedOn: nil), "detached")
    try check(try await library.keep(draft) == draft, "kept as itself")
  }

  private func basedOnKeptOnly() async throws {
    let library = try await library()
    let draft = try await library.saveDraft(avatar("Robot"), basedOn: nil)
    try await expect(AvatarLibraryError.notFound) {
      _ = try await library.saveDraft(avatar("Robot"), basedOn: draft)
    }
    try await expect(AvatarLibraryError.defaultAvatarIsFixed) {
      _ = try await library.saveDraft(avatar("Robot"), basedOn: .default)
    }
    try check(try await library.entries().count == 2, "nothing written")
  }

  private func updateDraft() async throws {
    let library = try await library()
    let draft = try await library.saveDraft(avatar("Robot", marker: 1), basedOn: nil)
    try await library.updateDraft(draft, with: avatar("Robot", marker: 3))
    try check(try await library.load(draft).sprites[.neutral] == sprite(3), "replaced")
    _ = try await library.keep(draft)
    try await expect(AvatarLibraryError.notADraft) {
      try await library.updateDraft(draft, with: avatar("Robot"))
    }
  }

  private func rename() async throws {
    let library = try await library()
    let robot = try await library.saveDraft(avatar("Robot"), basedOn: nil)
    try await library.rename(robot, to: "  Robot rétro menthe \n")
    try check(try await library.load(robot).manifest.name == "Robot rétro menthe", "cleaned")
    try check(
      try await library.entries().last?.manifest?.name == "Robot rétro menthe", "listed so")
    try await expect(AvatarLibraryError.emptyName) { try await library.rename(robot, to: " ") }
    try await expect(AvatarLibraryError.notFound) {
      try await library.rename(.stored(UUID()), to: "Robot")
    }
  }

  private func duplicateDefault() async throws {
    let library = try await library()
    let copy = try await library.duplicate(.default)
    let avatar = try await library.load(copy)
    try check(avatar.manifest.name == "Default Avatar (copy)", "named \(avatar.manifest.name)")
    try check(avatar.manifest.source == .imported, "imported")
    try check(avatar.sprites == (try await library.load(.default)).sprites, "same images")
    try check(try await library.entries().last?.state == .kept, "kept")
  }

  private func libraryLimit() async throws {
    let library = try await library()
    for _ in 0..<AvatarLibraryRules.maximumCount - 1 {
      _ = try await library.saveDraft(avatar("Robot"), basedOn: nil)
    }
    try check(try await library.canCreate(), "room for one more")
    // A generation starts at 19, and another avatar is imported meanwhile: 20.
    _ = try await library.saveDraft(avatar("Imported"), basedOn: nil)
    try check(try await !library.canCreate(), "full")
    let generated = try await library.saveDraft(avatar("Generated"), basedOn: nil)
    try check(try await library.entries().last?.id == generated, "written anyway")
    try await expect(AvatarLibraryError.limitReached) { _ = try await library.duplicate(.default) }
    try check(
      try await library.entries().count == AvatarLibraryRules.maximumCount + 2, "no copy made")
  }

  private func redrawAtLimit() async throws {
    let library = try await library(
      kept: (0..<AvatarLibraryRules.maximumCount).map { avatar("Robot \($0)") })
    try check(try await !library.canCreate(), "full")
    let robot = try await library.entries().last?.id ?? .default
    let draft = try await library.saveDraft(avatar("Robot", marker: 2), basedOn: robot)
    try check(try await !library.canCreate(), "still full")
    try check(try await library.keep(draft) == robot, "replaced")
    try check(
      try await library.entries().count == AvatarLibraryRules.maximumCount + 1, "as many")
  }

  private func missingDefault() async throws {
    let library = try await library(defaultAvatar: .some(nil))
    try check(try await library.entries().first?.problem == .unreadable, "says why")
    try await expect(AvatarStoreError.unreadable) { _ = try await library.load(.default) }
    try check(try await library.inUse() == .default, "in use all the same")
  }

  private func sizes() async throws {
    let library = try await library()
    var avatar = avatar("Robot")
    avatar.sheet = Data(count: 100)
    let robot = try await library.saveDraft(avatar, basedOn: nil)
    let entry = try await library.entries().first { $0.id == robot }
    let images = Int64(avatar.sprites.values.reduce(0) { $0 + $1.count } + 100)
    try check((entry?.byteCount ?? 0) >= images, "\(entry?.byteCount ?? 0) < \(images)")
  }

  private func redrawKeepsName() async throws {
    let library = try await library()
    let robot = try await library.saveDraft(avatar("Robot", marker: 1), basedOn: nil)
    _ = try await library.keep(robot)
    let place = try await library.entries().map(\.id)
    var redrawn = avatar("Robot", marker: 2)
    redrawn.manifest.description = "A mint robot"
    let draft = try await library.saveDraft(redrawn, basedOn: robot)
    try await library.rename(robot, to: "Robot rétro menthe")
    _ = try await library.keep(draft)
    let kept = try await library.load(robot)
    try check(kept.manifest.name == "Robot rétro menthe", "its name")
    try check(kept.manifest.description == "A mint robot", "the draft's description")
    try check(kept.sprites[.neutral] == sprite(2), "the draft's images")
    try check(try await library.entries().map(\.id) == place, "its place")
  }

  private func incompleteKept() async throws {
    let library = try await library(kept: [avatar("Old", missing: [.worried])])
    guard let old = try await library.entries().last else {
      throw Failure(description: "the kept avatar is not listed")
    }
    try check(old.problem == .incomplete([.worried]), "says what it lacks")
    try check(try await library.load(old.id).missingExpressions == [.worried], "read partly")
    try await expect(AvatarLibraryError.incomplete([.worried])) {
      try await library.setInUse(old.id)
    }
    try await expect(AvatarLibraryError.incomplete([.worried])) {
      _ = try await library.duplicate(old.id)
    }

    let draft = try await library.draftToComplete(old.id)
    try check(try await library.draftToComplete(old.id) == draft, "the same draft")
    try await expect(AvatarLibraryError.incomplete([.worried])) {
      _ = try await library.keep(draft)
    }
    try await library.updateDraft(draft, with: avatar("Old"))
    try check(try await library.keep(draft) == old.id, "completed in place")
    try check(try await library.entries().last?.problem == nil, "no longer incomplete")
    try await library.setInUse(old.id)
  }

  private func draftNotCopied() async throws {
    let library = try await library()
    let draft = try await library.saveDraft(avatar("Robot"), basedOn: nil)
    try await expect(AvatarLibraryError.notKept) { _ = try await library.duplicate(draft) }
    try await expect(AvatarLibraryError.notKept) { try await library.setInUse(draft) }
  }

  private func discardKeepsUse() async throws {
    let library = try await library()
    let robot = try await library.duplicate(.default)
    try await library.setInUse(robot)
    let draft = try await library.saveDraft(avatar("Robot"), basedOn: robot)
    try await library.remove(draft)
    try check(try await library.inUse() == robot, "still in use")
    try check(
      try await library.load(robot).manifest.name == "Default Avatar (copy)", "untouched")
  }

  private func useUnknown() async throws {
    let library = try await library()
    try await expect(AvatarLibraryError.notFound) { try await library.setInUse(.stored(UUID())) }
    try await expect(AvatarLibraryError.notFound) { _ = try await library.load(.stored(UUID())) }
    try await expect(AvatarLibraryError.notFound) { try await library.remove(.stored(UUID())) }
    try check(try await library.inUse() == .default, "default still")
  }

  private func removeInUse() async throws {
    let library = try await library()
    let robot = try await library.duplicate(.default)
    try await library.setInUse(robot)
    try await library.remove(robot)
    try check(try await library.inUse() == .default, "default back")
    try check(try await library.entries().map(\.id) == [.default], "gone")
  }
}
