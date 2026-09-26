import Foundation
import VibeApplication
import VibeDomain

extension ClaudeCodeAgentProvider: AgentConversationReporting {
  /// The transcript named after the conversation's identifier, and the one its last
  /// `SessionStart` named when that is another: a `/clear` starts a new file.
  public func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL] {
    let locator = AgentTranscriptLocator()
    var files: [URL] = []
    if let identifier = conversation.resumeIdentifier?.trimmingCharacters(in: .whitespaces),
      !identifier.isEmpty
    {
      files = locator.claudeTranscripts(for: identifier).filter {
        $0.lastPathComponent == "\(identifier).jsonl"
      }
    }
    if let path = hint?.string("transcript_path"), path.hasPrefix("/"),
      FileManager.default.fileExists(atPath: path)
    {
      let named = URL(fileURLWithPath: path)
      if !files.contains(named) { files.append(named) }
    }
    return files
  }

  public func conversationDecoder(for file: URL) -> any ConversationDecoding {
    ClaudeCodeConversationDecoder(file: file)
  }

  /// Claude Code keeps a prompt sent during a turn for when the turn ends, whatever the key.
  public var promptFormat: AgentPromptFormat {
    AgentPromptFormat()
  }
}

extension CodexAgentProvider: AgentConversationReporting {
  /// Every rollout of the conversation: resuming it another day starts a new file.
  public func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL] {
    guard let identifier = conversation.resumeIdentifier?.trimmingCharacters(in: .whitespaces),
      !identifier.isEmpty
    else { return [] }
    return AgentTranscriptLocator().codexRollouts(for: identifier, since: session.createdAt)
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  public func conversationDecoder(for file: URL) -> any ConversationDecoding {
    CodexConversationDecoder()
  }

  /// Return during a turn steers the turn under way; Tab queues the prompt for the next one, which
  /// is what a prompt typed while the agent works means here.
  public var promptFormat: AgentPromptFormat {
    AgentPromptFormat(queueKey: [0x09])
  }
}
