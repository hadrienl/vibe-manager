import Foundation
import VibeDomain

/// Implemented by the providers whose CLI writes a transcript the conversation view can read
/// (#38). A provider that does not has no conversation view, and its sessions show the terminal.
public protocol AgentConversationReporting: Sendable {
  /// The files one conversation was written to, oldest first. Empty while the CLI has written
  /// nothing yet: Claude Code writes its transcript at the first exchange, Codex its rollout at
  /// the first message.
  ///
  /// - Parameter hint: the event that named the transcript, when the agent's hooks reported one
  ///   (#45). It follows a `/clear`, which a resume identifier does not.
  func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL]

  /// A decoder for one file of this provider, fresh: it keeps what it read so far.
  func conversationDecoder(for file: URL) -> any ConversationDecoding

  /// How a prompt reaches this agent through its terminal.
  var promptFormat: AgentPromptFormat { get }
}

/// Turns the lines of one transcript into entries.
///
/// Stateful — a result names the call it answers, which came lines earlier — and used by one
/// reader at a time, so it is a class rather than a value.
public protocol ConversationDecoding: AnyObject {
  /// One complete line, in the order the CLI wrote it.
  func consume(_ line: Data)
  /// Everything read so far, in the order it happened.
  var entries: [ConversationEntry] { get }
}

/// How a prompt typed in the conversation view is written into an agent's terminal.
///
/// Measured against Claude Code 2.1.282 and Codex 0.157.0 in a real terminal (ADR 0023): both take
/// a bracketed paste of several lines as one prompt, keep its line breaks, and send it on Return.
public struct AgentPromptFormat: Hashable, Sendable {
  /// Written as one bracketed paste, so that a line break is text rather than a validation.
  public var usesBracketedPaste: Bool
  /// What sends the prompt.
  public var submitKey: [UInt8]
  /// What sends it while the agent works, for it to be taken up when the turn ends. Codex sends a
  /// prompt given Return into the turn under way, and queues one given Tab; Claude Code queues
  /// either way.
  public var queueKey: [UInt8]
  /// What stops the agent's turn: Escape for both CLIs.
  public var interruptKey: [UInt8]
  /// Between the paste and the key that sends it: a TUI that times keystrokes to tell a paste
  /// from typing must have seen the paste end.
  public var submitDelay: Duration

  public init(
    usesBracketedPaste: Bool = true,
    submitKey: [UInt8] = [0x0D],
    queueKey: [UInt8] = [0x0D],
    interruptKey: [UInt8] = [0x1B],
    submitDelay: Duration = .milliseconds(80)
  ) {
    self.usesBracketedPaste = usesBracketedPaste
    self.submitKey = submitKey
    self.queueKey = queueKey
    self.interruptKey = interruptKey
    self.submitDelay = submitDelay
  }
}

/// Follows a transcript file as the CLI appends to it.
public protocol TranscriptTailing: Sendable {
  /// Complete lines from the start of the file, then as they are written. `.reset` means the
  /// file was replaced or cut short: what was read from it is to be forgotten.
  func follow(_ file: URL) -> AsyncStream<TranscriptChunk>
  /// Reads the file once to its end, without following it.
  func read(_ file: URL) async -> [Data]
}

public enum TranscriptChunk: Sendable {
  case lines([Data])
  case reset
}
