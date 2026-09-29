import Foundation
import VibeApplication

/// Where the CLIs write their sub-agents' transcripts (#180, ADR 0034), found without opening them.
enum SubagentTranscripts {
  /// Claude Code writes, beside `<session id>.jsonl`, a folder `<session id>/subagents/` holding for
  /// each sub-agent `agent-<id>.jsonl` and, from the moment it starts, `agent-<id>.meta.json`
  /// naming the call that started it (`toolUseId`). Every sub-agent of the
  /// session is there, however deep. A skill run apart has no `toolUseId`: its call returns the
  /// sub-agent's identifier instead.
  static func claudeCode(beside root: URL) -> [SubagentTranscriptInfo] {
    let folder = root.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    let manager = FileManager.default
    guard
      let names = try? manager.contentsOfDirectory(atPath: folder.path)
    else { return [] }
    var found: [String: SubagentTranscriptInfo] = [:]
    for name in names where name.hasPrefix("agent-") {
      let agent: String
      if name.hasSuffix(".meta.json") {
        agent = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
      } else if name.hasSuffix(".jsonl") {
        agent = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
      } else {
        continue
      }
      guard !agent.isEmpty, found[agent] == nil else { continue }
      let transcript = folder.appendingPathComponent("agent-\(agent).jsonl")
      let meta = folder.appendingPathComponent("agent-\(agent).meta.json")
      let record =
        (try? Data(contentsOf: meta)).flatMap {
          try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
      let created =
        (try? manager.attributesOfItem(atPath: meta.path))?[.creationDate] as? Date
        ?? (try? manager.attributesOfItem(atPath: transcript.path))?[.creationDate] as? Date
      found[agent] = SubagentTranscriptInfo(
        agentID: agent, toolUseID: record["toolUseId"] as? String, file: transcript,
        createdAt: created)
    }
    return Array(found.values)
  }

  /// The prompt a Claude Code sub-agent's transcript starts with: its first line only.
  static func claudeCodeFirstPrompt(of file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var data = Data()
    // A first line longer than this is not a prompt worth comparing.
    while data.count < 1_048_576, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
      if let newline = chunk.firstIndex(of: 0x0A) {
        data.append(chunk[chunk.startIndex..<newline])
        break
      }
      data.append(chunk)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["type"] as? String == "user",
      let message = object["message"] as? [String: Any]
    else { return nil }
    if let text = message["content"] as? String { return text }
    let blocks = message["content"] as? [[String: Any]] ?? []
    let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    return texts.isEmpty ? nil : texts.joined(separator: "\n")
  }

  /// Codex writes each sub-agent's own rollout, `rollout-…-<thread id>.jsonl`, in the day folders
  /// of its sessions: found by the thread named in the conversation's `SubAgentActivity`.
  static func codex(beside root: URL, agentIDs: Set<String>) -> [SubagentTranscriptInfo] {
    guard !agentIDs.isEmpty else { return [] }
    // `sessions/YYYY/MM/DD/rollout-….jsonl`
    let sessions = root.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let locator = AgentTranscriptLocator(codexSessions: sessions)
    let started =
      (try? FileManager.default.attributesOfItem(atPath: root.path))?[.creationDate] as? Date
      ?? Date()
    return agentIDs.compactMap { agent in
      locator.codexRollouts(for: agent, since: started).first.map {
        SubagentTranscriptInfo(agentID: agent, file: $0)
      }
    }
  }
}
