import Foundation
import Security
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Where the endpoints are kept")
struct EndpointStoreTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeEndpoints-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Saved and read back in order; no file is no endpoint; a newer file is never overwritten")
  func file() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("endpoints.json")
    let repository = FileEndpointRepository(storeURL: url)
    #expect(try await repository.endpoints().isEmpty)

    let endpoints = [
      Endpoint(name: "B", baseURL: "http://localhost:11434", wireProtocol: .messages),
      Endpoint(name: "A", baseURL: "https://openrouter.ai/api/v1", wireProtocol: .chatCompletions),
    ]
    try await repository.save(endpoints)
    #expect(try await repository.endpoints() == endpoints)
    #expect(try FileEndpointRepository.read(url) == endpoints)

    try Data(#"{"schema":99,"endpoints":[]}"#.utf8).write(to: url)
    await #expect(throws: EndpointStoreError.self) { try await repository.endpoints() }
    await #expect(throws: EndpointStoreError.self) { try await repository.save([]) }
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("99"))
  }

  @Test("No secret is written to the file")
  func noSecretInFile() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("endpoints.json")
    let endpoint = Endpoint(
      name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", wireProtocol: .chatCompletions)
    let secrets = InMemoryEndpointSecretStore()
    secrets.setSecret("sk-VIBE-CANARY-\(UUID().uuidString)", for: endpoint.id)
    try await FileEndpointRepository(storeURL: url).save([endpoint])
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(!text.contains("VIBE-CANARY"))
  }

  @Test("The keychain keeps, replaces and forgets a secret")
  func keychain() throws {
    let store = KeychainEndpointSecretStore(
      service: "com.hadrienl.VibeManager.tests.\(UUID().uuidString)")
    let endpoint = EndpointID()
    do {
      try store.setSecret("first", for: endpoint)
    } catch EndpointSecretError.keychain(let status) where status == errSecInteractionNotAllowed {
      // A locked keychain, as on some CI runners: nothing to test here.
      return
    }
    defer { try? store.removeSecret(for: endpoint) }
    #expect(try store.secret(for: endpoint) == "first")
    try store.setSecret("second", for: endpoint)
    #expect(try store.secret(for: endpoint) == "second")
    #expect(store.hasSecret(for: endpoint))
    try store.removeSecret(for: endpoint)
    #expect(try store.secret(for: endpoint) == nil)
    try store.removeSecret(for: endpoint)
  }
}
