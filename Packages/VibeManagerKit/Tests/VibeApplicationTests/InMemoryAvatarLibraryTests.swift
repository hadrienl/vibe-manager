import Foundation
import Testing
import VibeApplication
import VibeAvatarLibraryTesting

@Suite("The library of avatars in memory")
struct InMemoryAvatarLibraryTests {
  static let contract = AvatarLibraryContract(sprite: { Data([$0]) }) { defaultAvatar, kept, now in
    InMemoryAvatarLibrary(defaultAvatar: defaultAvatar, kept: kept, now: now)
  }

  @Test("It does what every library does", arguments: AvatarLibraryContract.Case.allCases)
  func contract(_ contractCase: AvatarLibraryContract.Case) async throws {
    try await Self.contract.run(contractCase)
  }
}

@Suite("The avatar in use, as the screens of a single avatar see it")
struct LibraryAvatarStoreTests {
  let contract = InMemoryAvatarLibraryTests.contract

  func library(kept: [AvatarSpriteSet] = []) -> InMemoryAvatarLibrary {
    InMemoryAvatarLibrary(defaultAvatar: contract.avatar("Placeholder"), kept: kept)
  }

  @Test("The default avatar in use is no avatar")
  func defaultInUse() async throws {
    #expect(try await LibraryAvatarStore(library: library()).load() == nil)
  }

  @Test("Saving keeps the avatar and uses it; the one used before stays in the library")
  func save() async throws {
    let library = library()
    let store = LibraryAvatarStore(library: library)
    try await store.save(contract.avatar("Fox"))
    try await store.save(contract.avatar("Robot", marker: 2))

    #expect(try await store.load()?.manifest.name == "Robot")
    let entries = try await library.entries()
    #expect(entries.map { $0.manifest?.name } == ["Placeholder", "Fox", "Robot"])
    #expect(entries.allSatisfy { $0.state == .kept })
  }

  @Test("An incomplete avatar is not saved, and leaves nothing behind")
  func saveIncomplete() async throws {
    let library = library()
    let store = LibraryAvatarStore(library: library)
    await #expect(throws: AvatarLibraryError.incomplete([.worried])) {
      try await store.save(contract.avatar("Fox", missing: [.worried]))
    }
    #expect(try await library.entries().count == 1)
    #expect(try await store.load() == nil)
  }

  @Test("Back to the default avatar: the previous one is no longer used, and not deleted")
  func remove() async throws {
    let library = library()
    let store = LibraryAvatarStore(library: library)
    try await store.save(contract.avatar("Fox"))
    try await store.remove()
    #expect(try await store.load() == nil)
    #expect(try await library.entries().count == 2)
  }
}
