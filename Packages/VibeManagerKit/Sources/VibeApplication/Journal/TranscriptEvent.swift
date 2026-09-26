import Foundation
import VibeDomain

/// What a line of an agent's transcript says, once read (#36): the same few things whichever CLI
/// wrote it.
public enum TranscriptEvent: Hashable, Sendable {
  /// Something the user asked, the first prompt and the summaries handed over on a restart
  /// included.
  case prompt(String, at: Date?)
  case toolCall(TranscriptToolCall)
  /// What a command that creates a resource printed: the only outputs ever read, since a
  /// `gh issue list` prints eighty tickets the agent did not use.
  case creationOutput(command: String, directory: String?, output: String, at: Date?)
  /// What the agent said.
  case agentText(String, at: Date?)
  /// The agent finished answering.
  case turnEnded(at: Date?)
}

/// One call of a tool, as the journal needs it.
public struct TranscriptToolCall: Hashable, Sendable {
  /// `Bash`, `exec_command`, `WebFetch`, `mcp__gitlab__issues`…
  public var name: String
  /// The command line, for a tool that runs one.
  public var command: String?
  /// Where it ran.
  public var directory: String?
  /// The branch checked out there, when the transcript says so (Claude Code does).
  public var branch: String?
  /// Every other string of its input, searched for URLs.
  public var strings: [String]
  /// One line for the summary: `Bash: git push -u origin feat/36`, `Edit: Sources/App.swift`.
  public var summary: String
  public var at: Date?

  public init(
    name: String, command: String? = nil, directory: String? = nil, branch: String? = nil,
    strings: [String] = [], summary: String, at: Date? = nil
  ) {
    self.name = name
    self.command = command
    self.directory = directory
    self.branch = branch
    self.strings = strings
    self.summary = summary
    self.at = at
  }
}

/// The transcripts of a session read from where the last reading stopped.
public struct TranscriptReading: Sendable {
  /// Each conversation's events in order, with the agent that wrote them.
  public var events: [(providerID: String, event: TranscriptEvent)]
  /// Where the reading of each file stopped now.
  public var cursors: [String: TranscriptCursor]
  /// Whether any transcript of the session was found.
  public var foundTranscript: Bool

  public init(
    events: [(providerID: String, event: TranscriptEvent)] = [],
    cursors: [String: TranscriptCursor] = [:],
    foundTranscript: Bool = false
  ) {
    self.events = events
    self.cursors = cursors
    self.foundTranscript = foundTranscript
  }
}

/// Reads a session's transcripts incrementally, from cursors the journal keeps.
public protocol SessionJournalReading: Sendable {
  func read(_ session: WorkSession, from cursors: [String: TranscriptCursor]) async
    -> TranscriptReading
  /// The folders whose changes may concern the session's transcripts.
  func transcriptDirectories(for session: WorkSession) async -> [String]
}
