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
