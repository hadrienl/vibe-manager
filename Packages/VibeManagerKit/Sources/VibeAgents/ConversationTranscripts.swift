import Foundation
import VibeApplication
import VibeDomain

/// The transcripts one conversation of a session left: the files its CLI wrote, and in whose format.
struct ConversationTranscripts {
  let identifier: String
  let files: [URL]
  let isCodex: Bool
}

extension TranscriptLocationCache {
  /// Where a conversation's transcripts are, for every reader of them: the main file and its
  /// sub-agents' for Claude Code, every rollout for Codex, in the folders of the conversation's
  /// agent. `nil` for a conversation without an identifier, or an agent that writes none.
  func transcripts(of conversation: SessionAgentConfiguration, in session: WorkSession)
    -> ConversationTranscripts?
  {
    guard
      let identifier = conversation.resumeIdentifier?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return nil }
    switch conversation.transcriptProviderID {
    case ClaudeCodeAgentProvider.id.rawValue:
      // Once its file is found, only the folder of its sub-agents is listed again, where new ones
      // appear (#276).
      let main = claudeTranscript(
        for: identifier, providerID: conversation.providerID,
        workingDirectory: RestartSession.workingDirectoryPath(of: session))
      let files = main.map { [$0] + locator.claudeSubagents(of: $0, identifier: identifier) } ?? []
      return ConversationTranscripts(identifier: identifier, files: files, isCodex: false)
    case CodexAgentProvider.id.rawValue:
      let files = codexRollouts(
        for: identifier, providerID: conversation.providerID, since: session.createdAt
      ).sorted { $0.lastPathComponent < $1.lastPathComponent }
      return ConversationTranscripts(identifier: identifier, files: files, isCodex: true)
    default:
      return nil
    }
  }
}
