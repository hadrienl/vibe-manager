import Foundation
import VibeApplication
import VibeDomain

/// `agent-activity.json`, next to `sessions.json` and apart from it.
///
/// It changes at the end of every turn. Kept in the session store, it would move each session's
/// `updatedAt`, its backup and everything that watches the store, for a state that is not a fact
/// about the session but an observation of its process. Every way of failing to read it answers
/// nothing: losing it costs the unread marks, never a session.
public actor FileAgentActivityStateStore: AgentActivityStateStore {
  private static let currentSchemaVersion = 1

  private let url: URL

  public init(url: URL = FileAgentActivityStateStore.defaultURL()) {
    self.url = url
  }

  public static func defaultURL() -> URL {
    FileSessionRepository.defaultStoreURL()
      .deletingLastPathComponent()
      .appendingPathComponent("agent-activity.json", isDirectory: false)
  }

  public func read() -> [SessionID: PersistedAgentActivity] {
    guard let data = try? Data(contentsOf: url),
      let document = try? UsageStorage.decoder().decode(Document.self, from: data),
      document.schemaVersion == Self.currentSchemaVersion
    else { return [:] }
    var result: [SessionID: PersistedAgentActivity] = [:]
    for (key, activity) in document.sessions {
      guard let uuid = UUID(uuidString: key) else { continue }
      result[SessionID(rawValue: uuid)] = activity
    }
    return result
  }

  public func write(_ activities: [SessionID: PersistedAgentActivity]) {
    guard !activities.isEmpty else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    // Keyed by the plain UUID string, so the document can be read by hand next to the store.
    let document = Document(
      schemaVersion: Self.currentSchemaVersion,
      sessions: Dictionary(
        uniqueKeysWithValues: activities.map { ($0.key.rawValue.uuidString, $0.value) })
    )
    guard let data = try? UsageStorage.encoder(pretty: true).encode(document) else { return }
    try? UsageStorage.atomicWrite(data, to: url)
  }

  private struct Document: Codable {
    let schemaVersion: Int
    let sessions: [String: PersistedAgentActivity]
  }
}
