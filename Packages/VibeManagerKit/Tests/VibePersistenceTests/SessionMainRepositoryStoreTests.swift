import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping the repository of a session's worktree in the store (#525)")
struct SessionMainRepositoryStoreTests {
  private func session(_ name: String, path: String, main: String? = nil) -> WorkSession {
    WorkSession(
      name: name, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100),
      repositories: [RepositoryContext(path: path, mainRepositoryPath: main)])
  }

  @Test("The repository a worktree belongs to comes back with its session")
  func roundTrip() throws {
    let codec = SessionStoreCodec()
    let sessions = [
      session("TICKET-185", path: "/w/mairie/.claude/worktrees/TICKET-185", main: "/w/mairie"),
      session("mAIrie", path: "/w/mairie"),
    ]

    let decoded = try codec.decode(try codec.encode(sessions: sessions))

    #expect(!decoded.requiresRewrite)
    #expect(decoded.sessions.map(\.repositories.first?.mainRepositoryPath) == ["/w/mairie", nil])
    #expect(
      decoded.sessions[0].repositories.first?.path == "/w/mairie/.claude/worktrees/TICKET-185")
  }

  @Test("A store written before it reads as before, without being rewritten")
  func olderStoreReads() throws {
    let codec = SessionStoreCodec()
    let text = String(
      decoding: try codec.encode(sessions: [session("A", path: "/w/api")]), as: UTF8.self)
    #expect(!text.contains("mainRepositoryPath"))

    let decoded = try codec.decode(Data(text.utf8))

    #expect(!decoded.requiresRewrite)
    #expect(decoded.sessions.first?.repositories.first?.mainRepositoryPath == nil)
  }
}
