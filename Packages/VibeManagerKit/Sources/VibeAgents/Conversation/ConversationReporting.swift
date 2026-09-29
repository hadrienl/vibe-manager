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

  public func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  {
    SubagentTranscripts.claudeCode(beside: root)
  }

  public func subagentDecoder(for file: URL, root: URL) -> any ConversationDecoding {
    ClaudeCodeConversationDecoder(subagentFile: file)
  }

  public func firstPrompt(ofSubagent file: URL) -> String? {
    SubagentTranscripts.claudeCodeFirstPrompt(of: file)
  }

  /// Claude Code keeps a prompt sent during a turn for when the turn ends, whatever the key. It
  /// wraps any paste in `<pasted_content>` (2.1.283), and takes 4 kB arriving at once for one:
  /// typed 256 bytes every 20 ms, a prompt arrives as written.
  /// A command sent with `!` during a turn is queued as well, and run as a command once the turn
  /// ends (2.1.285).
  public var promptFormat: AgentPromptFormat {
    AgentPromptFormat(
      textEntry: .typed(chunkSize: 256, chunkDelay: .milliseconds(20)),
      shellEntry: ShellEntry(queuesWhileWorking: true))
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

  public func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  {
    SubagentTranscripts.codex(beside: root, agentIDs: agentIDs)
  }

  /// A sub-agent's rollout starts with a copy of its parent's history: left out.
  public func subagentDecoder(for file: URL, root: URL) -> any ConversationDecoding {
    CodexConversationDecoder(isFork: true)
  }

  /// Return during a turn steers the turn under way; Tab queues the prompt for the next one, which
  /// is what a prompt typed while the agent works means here.
  /// Its `!` command is written to the rollout once it ended (0.159).
  public var promptFormat: AgentPromptFormat {
    AgentPromptFormat(
      queueKey: [0x09],
      shellEntry: ShellEntry(
        isRecordedAtStart: false, messageGuard: CodexConversationDecoder.messageGuard))
  }
}
