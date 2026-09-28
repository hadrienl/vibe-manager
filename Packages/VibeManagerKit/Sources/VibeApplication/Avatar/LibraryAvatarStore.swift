import Foundation

/// The avatar in use of a library, as the screens of a single avatar see it (#154): "the" avatar is
/// the one in use, and none — the default one.
///
/// A bridge while the screens learn the library: nothing it does loses an avatar. Accepting a new
/// one keeps it beside the others, then uses it; going back to the default one only stops using
/// the previous one. Both stay in the library, where the next screens list them.
public struct LibraryAvatarStore: AvatarStore {
  private let library: any AvatarLibrary

  public init(library: any AvatarLibrary) {
    self.library = library
  }

  /// The avatar in use, whole; `nil` for the default one.
  /// - Throws: `AvatarStoreError` when it cannot be used as it is: the default one is shown
  ///   meanwhile.
  public func load() async throws -> AvatarSpriteSet? {
    let id = try await library.inUse()
    guard id != .default else { return nil }
    let avatar = try await library.load(id)
    guard avatar.isComplete else { throw AvatarStoreError.incomplete(avatar.missingExpressions) }
    return avatar
  }

  /// Writes the avatar as a draft, keeps it, then uses it. The one used before stays kept.
  public func save(_ avatar: AvatarSpriteSet) async throws {
    let draft = try await library.saveDraft(avatar, basedOn: nil)
    do {
      let kept = try await library.keep(draft)
      try await library.setInUse(kept)
    } catch {
      try? await library.remove(draft)
      throw error
    }
  }

  /// Back to the default avatar. The one used until now is not deleted.
  public func remove() async throws {
    try await library.setInUse(.default)
  }
}
