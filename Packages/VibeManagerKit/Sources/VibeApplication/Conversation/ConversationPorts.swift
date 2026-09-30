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

  /// The transcripts of the sub-agents of the conversation written to `root` (#180), listed
  /// without being opened. `agentIDs` are those the conversation named so far, for a CLI that
  /// finds a sub-agent's file by its identifier.
  func subagentTranscripts(beside root: URL, agentIDs: Set<String>) -> [SubagentTranscriptInfo]

  /// A decoder for the transcript of one of the sub-agents of the conversation written to `root`.
  func subagentDecoder(for file: URL, root: URL) -> any ConversationDecoding

  /// The first prompt a sub-agent's transcript holds: only read to tie a transcript that names no
  /// call to the call whose prompt it is.
  func firstPrompt(ofSubagent file: URL) -> String?
}

extension AgentConversationReporting {
  public func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  { [] }

  public func subagentDecoder(for file: URL, root: URL) -> any ConversationDecoding {
    conversationDecoder(for: file)
  }

  public func firstPrompt(ofSubagent file: URL) -> String? { nil }
}

/// Turns the lines of one transcript into entries.
///
/// Stateful — a result names the call it answers, which came lines earlier — and used by one
/// reader at a time, so it is a class rather than a value.
public protocol ConversationDecoding: AnyObject {
  /// One complete line, parsed, in the order the CLI wrote it.
  func consume(_ record: TranscriptRecord)
  /// Everything read so far, in the order it happened.
  var entries: [ConversationEntry] { get }
}

extension ConversationDecoding {
  /// One complete line, parsed here: for one-off readers and tests. A line that is not a JSON
  /// object is left out.
  public func consume(_ line: Data) {
    TranscriptRecord(line: line).map(consume)
  }
}

/// One line of a transcript, parsed ahead of its decoder, off the actor that decodes it (#249).
///
/// `JSONSerialization` without `.mutableContainers` hands out immutable containers: read from any
/// task, they are never written — hence the unchecked conformance. Keep it that way.
public struct TranscriptRecord: @unchecked Sendable {
  public let object: [String: Any]

  public init(_ object: [String: Any]) {
    self.object = object
  }

  /// The line parsed, or nil when it is not a JSON object.
  public init?(line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return nil
    }
    self.object = object
  }
}

/// How the text of a prompt reaches the agent's input.
public enum PromptTextEntry: Hashable, Sendable {
  /// The bytes as they are, for a program that reads a line at a time.
  case plain
  /// One bracketed paste, so that a line break is text rather than a validation.
  case bracketedPaste
  /// Typed, in pieces of at most `chunkSize` bytes `chunkDelay` apart: a TUI that tells a paste
  /// by the size of what arrives at once takes a longer piece for one. A line feed stays text.
  case typed(chunkSize: Int, chunkDelay: Duration)
}

/// How a command reaches an agent's shell mode: `!` typed first in its prompt runs the rest as a
/// shell command, whose output the agent reads with the conversation (#188).
///
/// Measured against Claude Code 2.1.285 and Codex 0.159.0 in a real terminal: `!` typed alone on
/// an empty prompt switches it to a shell prompt, and a command then typed — line feeds
/// included — runs as one on Return. The command is typed, never pasted: pasted, a text opening on
/// `!` may stay text.
public struct ShellEntry: Hashable, Sendable {
  /// Typed alone, on an empty prompt: what turns it into a shell prompt.
  public var trigger: [UInt8]
  /// Between the trigger and the command, for the prompt to be redrawn as a shell one. 20 ms was
  /// enough for Claude Code.
  public var switchDelay: Duration
  public var chunkSize: Int
  public var chunkDelay: Duration
  /// Whether a command sent while the agent works waits for the turn to end. Claude Code queues
  /// it, then runs it as a command; Codex was not measured, and nothing is written to it then.
  public var queuesWhileWorking: Bool
  /// Whether the command is written to the transcript as it starts — Claude Code — or once it
  /// ended — Codex: then it may take long before the transcript says anything of it.
  public var isRecordedAtStart: Bool
  /// Put before a message opening on `!` for it to stay text. Claude Code takes a pasted `!` for
  /// text; Codex runs it — spaces before it included, which it trims — but not after a zero-width
  /// space, its model reading the message as written.
  public var messageGuard: String

  public init(
    trigger: [UInt8] = Array("!".utf8),
    switchDelay: Duration = .milliseconds(80),
    chunkSize: Int = 256,
    chunkDelay: Duration = .milliseconds(20),
    queuesWhileWorking: Bool = false,
    isRecordedAtStart: Bool = true,
    messageGuard: String = ""
  ) {
    self.messageGuard = messageGuard
    self.trigger = trigger
    self.switchDelay = switchDelay
    self.chunkSize = chunkSize
    self.chunkDelay = chunkDelay
    self.queuesWhileWorking = queuesWhileWorking
    self.isRecordedAtStart = isRecordedAtStart
  }
}

/// How a prompt typed in the conversation view is written into an agent's terminal.
///
/// Measured against Claude Code 2.1.282 and Codex 0.157.0 in a real terminal (ADR 0025): both take
/// a bracketed paste of several lines as one prompt, keep its line breaks, and send it on Return.
/// Claude Code 2.1.283 records a pasted text as `<pasted_content>`, which its model then takes for
/// something the user did not write: it has the text typed instead.
public struct AgentPromptFormat: Hashable, Sendable {
  public var textEntry: PromptTextEntry
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
  /// Added to that wait for each file joined to the prompt. Claude Code reads an image whose path
  /// was pasted before it takes the next key: with two screenshots, a Return 80 ms after the
  /// paste was lost and the prompt stayed in its input (#99).
  public var attachmentDelay: Duration
  /// `nil` for an agent without a shell mode: a `!` typed first is then text (#188).
  public var shellEntry: ShellEntry?

  public init(
    textEntry: PromptTextEntry = .bracketedPaste,
    submitKey: [UInt8] = [0x0D],
    queueKey: [UInt8] = [0x0D],
    interruptKey: [UInt8] = [0x1B],
    submitDelay: Duration = .milliseconds(80),
    attachmentDelay: Duration = .milliseconds(500),
    shellEntry: ShellEntry? = nil
  ) {
    self.shellEntry = shellEntry
    self.textEntry = textEntry
    self.submitKey = submitKey
    self.queueKey = queueKey
    self.interruptKey = interruptKey
    self.submitDelay = submitDelay
    self.attachmentDelay = attachmentDelay
  }

  /// How long to wait between the paste and the key that sends it: three seconds at most.
  public func delayBeforeSubmit(attachmentCount: Int) -> Duration {
    submitDelay + min(attachmentDelay * attachmentCount, .seconds(3))
  }
}

/// Follows a transcript file as the CLI appends to it.
public protocol TranscriptTailing: Sendable {
  /// Complete lines from `position` — the start of the file when nil — then as they are written.
  /// `.reset` means the file was replaced or cut short, or is no longer the one `position` was
  /// in: what was read from it is to be forgotten, and it is read again from its start.
  func follow(_ file: URL, from position: TranscriptPosition?) -> AsyncStream<TranscriptChunk>
  /// Reads the file once to its end, without following it.
  func read(_ file: URL) async -> [TranscriptRecord]
}

extension TranscriptTailing {
  /// Complete lines from the start of the file, then as they are written.
  public func follow(_ file: URL) -> AsyncStream<TranscriptChunk> {
    follow(file, from: nil)
  }
}

public enum TranscriptChunk: Sendable {
  /// Complete lines, parsed, in the order of the file; lines that are not JSON objects are left
  /// out. `through` is where the reading stands after them, to resume it there; `isCaughtUp` says
  /// the file held nothing more once they were read.
  case records([TranscriptRecord], through: TranscriptPosition? = nil, isCaughtUp: Bool)
  case reset
}

/// Where a reading of a transcript stands (#249): resumable while the file is the same one.
public struct TranscriptPosition: Hashable, Sendable {
  public var inode: UInt64
  /// Where the complete lines read end.
  public var offset: UInt64
  /// The last bytes before `offset`, 64 at most: a file rewritten in place — same inode, as long
  /// or longer — no longer has them there, and is read again from its start.
  public var fingerprint: Data

  public init(inode: UInt64, offset: UInt64, fingerprint: Data) {
    self.inode = inode
    self.offset = offset
    self.fingerprint = fingerprint
  }
}
