import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping a session's conversation theme in the store")
struct SessionConversationThemeStoreTests {
  private func session(_ name: String, theme: String? = nil, rank: Int = 0) -> WorkSession {
    WorkSession(
      name: name, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), rank: rank, conversationTheme: theme)
  }

  @Test("A v9 store keeps the theme chosen, and the sessions that follow the settings")
  func roundTrip() throws {
    let codec = SessionStoreCodec()
    let sessions = [session("Prod", theme: "night"), session("Free")]

    let decoded = try codec.decode(try codec.encode(sessions: sessions))

    #expect(!decoded.requiresRewrite)
    #expect(decoded.sessions.map(\.conversationTheme) == ["night", nil])
  }

  @Test("A v8 store follows the settings everywhere, keeps its ranks, and is rewritten in v9")
  func v8IsMigrated() throws {
    let codec = SessionStoreCodec()
    let v9 = String(
      decoding: try codec.encode(sessions: [session("A", rank: 5), session("B", rank: -2)]),
      as: UTF8.self)
    #expect(v9.contains(#""schemaVersion" : 10"#))
    let v8 = v9.replacingOccurrences(of: #""schemaVersion" : 10"#, with: #""schemaVersion" : 8"#)

    let decoded = try codec.decode(Data(v8.utf8))

    #expect(decoded.requiresRewrite)
    #expect(decoded.sessions.map(\.conversationTheme) == [nil, nil])
    #expect(decoded.sessions.map(\.rank) == [5, -2])
  }

  @Test("An empty theme, which no build writes, follows the settings instead of failing the store")
  func emptyThemeIsIgnored() throws {
    let codec = SessionStoreCodec()
    let text = String(
      decoding: try codec.encode(sessions: [session("A", theme: "paper")]), as: UTF8.self
    )
    .replacingOccurrences(of: #""conversationTheme" : "paper""#, with: #""conversationTheme" : """#)

    let decoded = try codec.decode(Data(text.utf8))

    #expect(decoded.sessions.first?.conversationTheme == nil)
  }

  @Test("A theme that names nothing known is kept as written")
  func unknownThemeIsKept() throws {
    let codec = SessionStoreCodec()
    let decoded = try codec.decode(
      try codec.encode(sessions: [session("A", theme: "personal-deleted")]))
    #expect(decoded.sessions.first?.conversationTheme == "personal-deleted")
  }
}

@Suite("The conversation theme of a template on disk")
struct PromptTemplateConversationThemeStoreTests {
  @Test("The theme survives the store and an export, and a file without one reads as none")
  func themeRoundTrips() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("templates-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("templates.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let template = PromptTemplate(name: "Prod", body: "x", conversationTheme: "night")
    let now = Date()
    try await FilePromptTemplateRepository(storeURL: url).update { library in
      _ = try library.save(template, at: now)
    }
    let stored = try await FilePromptTemplateRepository(storeURL: url).library()
    #expect(stored.templates.first?.conversationTheme == "night")

    let codec = PromptTemplateExchangeCodec()
    let exported = try codec.encode(stored.templates, exportedAt: now)
    #expect(try codec.decode(exported, importedAt: now).first?.conversationTheme == "night")

    let withoutTheme = Data(
      #"{"format":"vibe-manager.prompt-templates","version":1,"templates":[{"id":"6F1C2A4E-7D35-4B8A-9E61-2C0D5B7A1E09","name":"N","body":"b"}]}"#
        .utf8)
    #expect(try codec.decode(withoutTheme, importedAt: now).first?.conversationTheme == nil)
  }
}
