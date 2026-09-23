import Foundation
import VibeDomain

/// What a restarted agent is told about the session it is picking up, when its own conversation
/// could not be resumed.
///
/// Everything in it was already stored on the session: nothing is read from disk, nothing is
/// asked of a model, and the same session always produces the same text. That is what makes it
/// safe to show to the user before it is sent — a summary they cannot predict is one they cannot
/// check.
public struct SessionContextBrief: Hashable, Sendable {
  /// The parts a brief is made of, in the order they are written.
  ///
  /// They are given up in a different order — the initial instruction first, then the notes, then
  /// the folders — because the older a section is, the less of it still holds: an instruction
  /// written days ago against files that have moved has aged more than the folder it was given in.
  /// `heading`, `agent` and `instruction` are never dropped: a summary without them would not say
  /// which work is being resumed, which is the one thing the agent cannot infer.
  public enum Section: String, Hashable, Sendable, CaseIterable {
    case heading
    case agent
    /// A handover only: the agents that worked in the session before.
    case agents
    case folders
    /// A handover only: the repositories read in the branch report, and where each one stands.
    case repositories
    /// A handover only: the repositories the agent went into and left untouched.
    case visited
    case notes
    case task
    case instruction
  }

  public let text: String
  public let isTruncated: Bool
  public let includedSections: [Section]
  /// How many bytes the text is over what an agent can be started with. Only a handover can be:
  /// it never cuts the prompt the session was created with, and leaves the shortening to the user.
  public let overflowByteCount: Int

  public init(
    text: String,
    isTruncated: Bool,
    includedSections: [Section],
    overflowByteCount: Int = 0
  ) {
    self.text = text
    self.isTruncated = isTruncated
    self.includedSections = includedSections
    self.overflowByteCount = overflowByteCount
  }

  public var fits: Bool { overflowByteCount == 0 }
}

/// Builds the brief of a session, and nothing else.
///
/// Pure by construction — a session and a byte limit in, a string out — so every wording, every
/// omission and every truncation is covered by a test that needs no CLI, no disk and no clock.
public struct SessionContextBriefBuilder: Sendable {
  /// The ceiling the text is kept under. It defaults to what the providers accept as an
  /// argument: both CLIs refuse to take a prompt on the standard input, because in a pseudo
  /// terminal the standard input is the keyboard, so a brief that does not fit in `argv` is a
  /// brief that cannot be delivered at all.
  public let byteLimit: Int

  public init(byteLimit: Int = AgentPromptLimits.argumentByteLimit) {
    self.byteLimit = byteLimit
  }

  public func callAsFunction(for session: WorkSession) -> SessionContextBrief {
    var sections = allSections(of: session)
    var isTruncated = false

    // Dropped whole rather than cut in half: half a note reads like a complete one, and the
    // agent has no way to tell that the sentence it is acting on was severed.
    for droppable in [SessionContextBrief.Section.task, .notes, .folders] {
      guard byteCount(of: sections, truncated: isTruncated) > byteLimit else { break }
      guard sections.contains(where: { $0.section == droppable }) else { continue }
      sections.removeAll { $0.section == droppable }
      isTruncated = true
    }

    var text = assemble(sections, truncated: isTruncated)
    if text.utf8.count > byteLimit {
      // The floor: heading, agent and instruction alone are still too long, which takes a name
      // of several kilobytes. Cut by scalars so the text stays valid UTF-8.
      isTruncated = true
      text = clamp(assemble(sections, truncated: true), to: byteLimit)
    }

    return SessionContextBrief(
      text: text,
      isTruncated: isTruncated,
      includedSections: sections.map(\.section)
    )
  }

  /// Keeps a text the user edited within the same ceiling, so an edited brief can never fail a
  /// launch the generated one would have passed.
  public func clamped(_ text: String) -> String {
    guard text.utf8.count > byteLimit else { return text }
    return clamp(text, to: byteLimit)
  }

  // MARK: - Sections

  private struct Part {
    let section: SessionContextBrief.Section
    let text: String
  }

  private func allSections(of session: WorkSession) -> [Part] {
    var parts: [Part] = [Part(section: .heading, text: heading(of: session))]

    if let agent = session.agent {
      parts.append(Part(section: .agent, text: agentLine(agent, in: session)))
    }
    if let folders = folders(of: session) {
      parts.append(Part(section: .folders, text: folders))
    }
    if let notes = session.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
      !notes.isEmpty
    {
      parts.append(Part(section: .notes, text: "Notes kept on this session:\n\(notes)"))
    }
    let prompt = session.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !prompt.isEmpty {
      // Quoted as history, not restated as an order: it was given days ago, against files that
      // have moved since, and handing it back as the task would restart the work from scratch.
      parts.append(
        Part(
          section: .task,
          text: "The instruction this session was created with, for context:\n\(prompt)"
        )
      )
    }
    parts.append(Part(section: .instruction, text: Self.instruction))
    return parts
  }

  func heading(of session: WorkSession) -> String {
    var line = "Session: \(session.name)"
    line += "\nCreated \(Self.date(session.createdAt))"
    if let closedAt = session.closedAt {
      line += ", last agent stopped \(Self.date(closedAt))"
    }
    line += "."
    return line
  }

  private func agentLine(_ agent: SessionAgentConfiguration, in session: WorkSession) -> String {
    var line = "Agent: \(Self.label(agent, names: [:]))"
    // After a switch, a restarted agent is told another one worked here: the files may hold work
    // its own conversation knows nothing about.
    let previous = session.agentHistory.filter { $0.outcome == .completed }.map(\.previous)
    if !previous.isEmpty {
      line += " (previously \(previous.map { Self.label($0, names: [:]) }.joined(separator: ", ")))"
    }
    return line
  }

  /// "Claude Code · opus": the agent's name when it is known, its identifier otherwise.
  static func label(_ agent: SessionAgentConfiguration, names: [String: String]) -> String {
    var line = names[agent.providerID] ?? agent.providerID
    if let modelID = agent.modelID {
      line += " · \(modelID)"
    }
    return line
  }

  func folders(of session: WorkSession) -> String? {
    guard !session.repositories.isEmpty else { return nil }
    let lines = session.repositories.map { repository -> String in
      var line = "- \(repository.path)"
      guard let git = repository.git else { return line }

      var facts: [String] = []
      if let branch = git.branchName {
        facts.append("branch \(branch)")
      }
      if let head = git.headRevision {
        facts.append("at \(String(head.prefix(7)))")
      }
      facts.append(git.isDirty ? "with uncommitted changes" : "with a clean worktree")
      if let worktree = git.worktreePath, worktree != repository.path {
        facts.append("worktree \(worktree)")
      }
      // Dated on purpose. A snapshot taken three days ago, written in the present tense, would
      // have the agent reason about a branch that may no longer exist.
      line += " — \(facts.joined(separator: ", ")), recorded \(Self.date(git.capturedAt))"
      return line
    }
    return (["Folders, as they were when this was recorded:"] + lines).joined(separator: "\n")
  }

  private static let instruction = """
    Pick this work up from the current state of these files. Read whatever you need rather than \
    trusting the details above: they were recorded earlier and may have moved since.
    """

  private static let preamble = """
    This session is being restarted in a new process, because its previous conversation could \
    not be resumed. Nothing below comes from that conversation — it is what Vibe Manager had \
    recorded about the session.
    """

  private static let truncationNotice = "(This summary was shortened to fit.)"

  // MARK: - Assembling

  private func assemble(_ parts: [Part], truncated: Bool) -> String {
    var blocks = [Self.preamble]
    blocks.append(contentsOf: parts.map(\.text))
    if truncated {
      blocks.append(Self.truncationNotice)
    }
    return blocks.joined(separator: "\n\n")
  }

  private func byteCount(of parts: [Part], truncated: Bool) -> Int {
    assemble(parts, truncated: truncated).utf8.count
  }

  func clamp(_ text: String, to limit: Int) -> String {
    var result = ""
    var count = 0
    for character in text {
      let size = String(character).utf8.count
      guard count + size <= limit else { break }
      result.append(character)
      count += size
    }
    return result
  }

  /// One fixed, locale-independent spelling of a date, in the reader's own time zone.
  ///
  /// The brief is read by an agent and compared by tests, so its *shape* must not follow the
  /// user's region. Its time zone does: "closed at 18:40" is about the afternoon the user
  /// remembers, not about UTC. Two Macs in different zones therefore render the same session
  /// differently, which is the one thing the summary is not identical about, and the right one.
  static func date(_ date: Date) -> String {
    formatter.string(from: date)
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
    return formatter
  }()
}
