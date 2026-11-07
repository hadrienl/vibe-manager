import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The file of the agents' accounts")
struct FileAgentAccountRepositoryTests {
  private func url() -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-accounts-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("agent-accounts.json")
  }

  @Test("What is saved is read back, and no file means no account")
  func roundTrip() async throws {
    let repository = FileAgentAccountRepository(storeURL: url())
    #expect(try await repository.accounts().isEmpty)
    let account = AgentAccount(name: "Perso", harness: .codex, configurationDirectory: "~/.c2")
    try await repository.save([account])
    #expect(try await repository.accounts() == [account])
  }

  @Test("A damaged file is never written over")
  func damaged() async throws {
    let file = url()
    try Data("nope".utf8).write(to: file)
    let repository = FileAgentAccountRepository(storeURL: file)
    await #expect(throws: AgentAccountStoreError.self) { try await repository.save([]) }
    #expect(try Data(contentsOf: file) == Data("nope".utf8))
  }
}
