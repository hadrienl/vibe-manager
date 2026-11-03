import Foundation
import VibeApplication
import VibeDomain

/// The agents' extra accounts (#478), in `agent-accounts.json` next to `sessions.json`. A file
/// that cannot be read, or that a newer version wrote, is never written over.
public actor FileAgentAccountRepository: AgentAccountRepository {
  static let schema = 1

  private let storeURL: URL

  public init(storeURL: URL) {
    self.storeURL = storeURL
  }

  struct Stored: Codable {
    var schema: Int
    var accounts: [AgentAccount]
  }

  public func accounts() throws -> [AgentAccount] {
    try Self.read(storeURL)
  }

  /// Also read before the workspace loads: a session kept running must find its agent.
  public static func read(_ url: URL) throws -> [AgentAccount] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AgentAccountStoreError.unreadable(reason: error.localizedDescription)
    }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      throw AgentAccountStoreError.unreadable(
        reason: String(localized: "the file is damaged.", bundle: .module))
    }
    guard stored.schema <= schema else {
      throw AgentAccountStoreError.unreadable(
        reason: String(
          localized: "the file was written by a newer version of Vibe Manager.", bundle: .module))
    }
    return stored.accounts
  }

  public func save(_ accounts: [AgentAccount]) throws {
    // Refused over a file that cannot be read: its bytes would be lost.
    _ = try self.accounts()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      let data = try encoder.encode(Stored(schema: Self.schema, accounts: accounts))
      try AtomicFileWriter.write(data, to: storeURL)
    } catch {
      throw AgentAccountStoreError.cannotWrite(reason: error.localizedDescription)
    }
  }
}
