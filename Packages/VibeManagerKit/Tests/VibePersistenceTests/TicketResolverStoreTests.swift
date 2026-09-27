import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The ticket resolver store (#89)")
struct FileTicketResolverRepositoryTests {
  private func makeURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("tickets-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("ticket-resolvers.json")
  }

  @Test("No file gives the shipped presets")
  func shipped() async throws {
    let store = FileTicketResolverRepository(storeURL: makeURL())
    let document = try await store.document()
    #expect(document.current.map(\.id) == TicketResolverPresets.all.map(\.id))
  }

  @Test("Resolvers survive a round trip in their order; a deleted preset stays deleted")
  func roundTrip() async throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = FileTicketResolverRepository(storeURL: url)
    let redmine = TicketResolver(
      name: "Redmine", pattern: #"https://redmine\.acme\.fr/issues/(?<number>[0-9]+)"#,
      shortID: "#{number}")
    try await store.save([redmine, TicketResolverPresets.github])

    let document = try await FileTicketResolverRepository(storeURL: url).document()
    #expect(document.current.map(\.name) == ["Redmine", "GitHub"])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }

  @Test("A file that cannot be read is never written over")
  func unreadable() async throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    let store = FileTicketResolverRepository(storeURL: url)

    await #expect(throws: TicketResolverStoreError.self) { try await store.document() }
    await #expect(throws: TicketResolverStoreError.self) {
      try await store.save(TicketResolverPresets.all)
    }
    #expect(try Data(contentsOf: url) == Data("not json".utf8))
  }

  @Test("A file from a newer version is not read")
  func newer() async throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"schema": 2, "knownPresets": [], "resolvers": []}"#.utf8).write(to: url)
    await #expect(throws: TicketResolverStoreError.self) {
      try await FileTicketResolverRepository(storeURL: url).document()
    }
  }
}

@Suite("The ticket title preferences (#89)")
@MainActor
struct UserDefaultsTicketTitlePreferencesTests {
  @Test("On by default with the standard line; an invalid format is not kept")
  func defaults() {
    let suite = "tickets-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsTicketTitlePreferences(suiteName: suite)
    #expect(preferences.insertsTicketTitles)
    #expect(preferences.lineFormat == .standard)
    preferences.insertsTicketTitles = false
    preferences.lineFormat = TicketLineFormat("- {title}")
    let again = UserDefaultsTicketTitlePreferences(suiteName: suite)
    #expect(!again.insertsTicketTitles)
    #expect(again.lineFormat.template == "- {title}")
    again.lineFormat = TicketLineFormat("{id}")
    #expect(UserDefaultsTicketTitlePreferences(suiteName: suite).lineFormat == .standard)
  }
}
