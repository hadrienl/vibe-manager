import Foundation

/// One line of a session's summary: a short action, in the past tense, as the agent's own CLI
/// wrote it.
public struct JournalEntry: Hashable, Codable, Sendable, Identifiable {
  public let id: UUID
  /// Empty for the entry that stands for older entries folded away.
  public let text: String
  /// When the turn it describes ended.
  public let at: Date
  /// The agent whose turn it describes.
  public let providerID: String?
  /// How many older entries this one stands for, when the journal outgrew its bound.
  public let foldedCount: Int?

  public init(
    id: UUID = UUID(), text: String, at: Date, providerID: String?, foldedCount: Int? = nil
  ) {
    self.id = id
    self.text = text
    self.at = at
    self.providerID = providerID
    self.foldedCount = foldedCount
  }
}

/// Where the reading of one transcript file stopped.
public struct TranscriptCursor: Hashable, Codable, Sendable {
  /// Bytes read, up to the last complete line.
  public var offset: UInt64
  /// The file it was, so that a file replaced by another of the same name is read from the start.
  public var inode: UInt64?

  public init(offset: UInt64 = 0, inode: UInt64? = nil) {
    self.offset = offset
    self.inode = inode
  }
}

/// A turn of the agent not summarized yet: what the user asked, what the agent did, what it said
/// last. Kept in the journal rather than read again from the transcript, so a summary that failed
/// can be tried again after a relaunch, even once the CLI has cleaned its transcripts away.
public struct DigestTurn: Hashable, Codable, Sendable {
  /// Which turn: a pass removes the turns it summarized by it, whatever came in meanwhile.
  public var id: UUID
  public var prompts: [String]
  /// One line per action: `Bash: git push -u origin feat/36`, `Edit: Sources/…/Journal.swift`.
  public var actions: [String]
  /// Actions past the bound, counted rather than kept.
  public var omittedActions: Int
  public var agentText: String?
  /// `nil` while the turn is still going on.
  public var endedAt: Date?
  /// The agent that did it.
  public var providerID: String?

  public init(
    id: UUID = UUID(), prompts: [String] = [], actions: [String] = [], omittedActions: Int = 0,
    agentText: String? = nil, endedAt: Date? = nil, providerID: String? = nil
  ) {
    self.id = id
    self.prompts = prompts
    self.actions = actions
    self.omittedActions = omittedActions
    self.agentText = agentText
    self.endedAt = endedAt
    self.providerID = providerID
  }

  public var isEmpty: Bool {
    prompts.isEmpty && actions.isEmpty && omittedActions == 0 && agentText == nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, prompts, actions, omittedActions, agentText, endedAt, providerID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      prompts: try container.decodeIfPresent([String].self, forKey: .prompts) ?? [],
      actions: try container.decodeIfPresent([String].self, forKey: .actions) ?? [],
      omittedActions: try container.decodeIfPresent(Int.self, forKey: .omittedActions) ?? 0,
      agentText: try container.decodeIfPresent(String.self, forKey: .agentText),
      endedAt: try container.decodeIfPresent(Date.self, forKey: .endedAt),
      providerID: try container.decodeIfPresent(String.self, forKey: .providerID))
  }
}

/// Where the summary stands.
public enum JournalSummaryState: Hashable, Codable, Sendable {
  /// Nothing went wrong, or nothing was tried yet.
  case ready
  /// The session's agent cannot write one, and why.
  case unavailable(JournalSummaryUnavailability)
  /// The last pass failed, and how many in a row did.
  case failed(at: Date, attempts: Int)
}

public enum JournalSummaryUnavailability: String, Hashable, Codable, Sendable {
  /// This agent has no way to summarize at all.
  case unsupported
  /// Its CLI is too old for the options a summary needs.
  case outdated
  /// Its CLI is not signed in.
  case signedOut
  /// Its CLI is missing or cannot run.
  case missing
}

/// What a session did, kept apart from the session store (#36): a short summary written by the
/// session's agent, the tickets, requests, branches and worktrees it used, and where the reading of
/// its transcripts stopped.
///
/// Only ever appended to. Entries are never rewritten, so the list does not move under the user's
/// eyes, and a failed pass loses nothing.
public struct SessionJournal: Hashable, Codable, Sendable {
  public static let schemaVersion = 1
  /// Past this, the oldest entries are folded into one.
  public static let entryLimit = 500
  /// Past this, resources are counted and no longer kept.
  public static let resourceLimit = 1_000
  /// Turns waiting to be summarized, the oldest dropped past it.
  ///
  /// These bounds keep a journal well under the store's limit: 20 turns of 5 prompts of 1,000
  /// characters, 60 actions of 200 and 1,500 of the agent's words weigh about 450 KB at worst.
  public static let pendingTurnLimit = 20
  /// Prompts kept for one turn: the latest.
  public static let promptLimit = 5
  /// Actions kept for one turn, the others counted.
  public static let actionLimit = 60

  public var schema: Int
  public var entries: [JournalEntry]
  public var resources: [SessionResource]
  /// Resources seen past `resourceLimit`.
  public var overflowResourceCount: Int
  /// By transcript file path.
  public var cursors: [String: TranscriptCursor]
  /// Turns not summarized yet; the last one may still be going on.
  public var pending: [DigestTurn]
  public var summary: JournalSummaryState
  /// Whether any turn of the agent ever ended: until then, there is nothing to summarize.
  public var hasEndedTurn: Bool
  /// When the last summary was written.
  public var summarizedAt: Date?

  public init(
    entries: [JournalEntry] = [],
    resources: [SessionResource] = [],
    overflowResourceCount: Int = 0,
    cursors: [String: TranscriptCursor] = [:],
    pending: [DigestTurn] = [],
    summary: JournalSummaryState = .ready,
    hasEndedTurn: Bool = false,
    summarizedAt: Date? = nil
  ) {
    schema = Self.schemaVersion
    self.entries = entries
    self.resources = resources
    self.overflowResourceCount = overflowResourceCount
    self.cursors = cursors
    self.pending = pending
    self.summary = summary
    self.hasEndedTurn = hasEndedTurn
    self.summarizedAt = summarizedAt
  }

  // MARK: - Resources

  /// Adds what was seen, in the order it was first seen. A resource seen again is merged into the
  /// one already listed, in place.
  ///
  /// - Returns: whether anything changed.
  @discardableResult
  public mutating func record(_ sightings: [SessionResource]) -> Bool {
    var changed = false
    var positions = Dictionary(
      resources.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })
    for sighting in sightings {
      if let index = positions[sighting.key] {
        let merged = resources[index].merging(sighting)
        if merged != resources[index] {
          resources[index] = merged
          changed = true
        }
      } else if resources.count < Self.resourceLimit {
        positions[sighting.key] = resources.count
        resources.append(sighting)
        changed = true
      } else {
        overflowResourceCount += 1
        changed = true
      }
    }
    return changed
  }

  // MARK: - Entries

  /// Appends new entries after the others, folding the oldest into one past the bound.
  public mutating func append(_ new: [JournalEntry]) {
    entries.append(contentsOf: new)
    guard entries.count > Self.entryLimit else { return }
    // One entry stands for everything folded, the previous folded one included.
    let excess = entries.count - Self.entryLimit + 1
    let folded = entries.prefix(excess)
    let count = folded.reduce(0) { $0 + ($1.foldedCount ?? 1) }
    let first = JournalEntry(
      text: "", at: folded.last?.at ?? Date(), providerID: nil, foldedCount: count)
    entries = [first] + entries.dropFirst(excess)
  }

  // MARK: - Turns waiting for a summary

  /// The turns that ended and wait for a summary.
  public var endedTurns: [DigestTurn] {
    Array(pending.prefix { $0.endedAt != nil })
  }

  /// The turn being written to, opened when needed.
  public mutating func withOpenTurn(
    providerID: String?, _ change: (inout DigestTurn) -> Void
  ) {
    if pending.last?.endedAt != nil || pending.isEmpty {
      pending.append(DigestTurn(providerID: providerID))
    }
    change(&pending[pending.count - 1])
    if pending.count > Self.pendingTurnLimit {
      pending.removeFirst(pending.count - Self.pendingTurnLimit)
    }
  }

  /// Ends the turn being written to. A turn in which nothing happened is not one: Claude Code
  /// says a turn ended twice, and a sub-agent says it too.
  public mutating func endTurn(at date: Date) {
    guard let last = pending.last, last.endedAt == nil, !last.isEmpty else { return }
    pending[pending.count - 1].endedAt = date
    hasEndedTurn = true
  }

  /// These turns are summarized: they are no longer pending. By identity, not position: turns
  /// that ended during the pass, or fell off the bound, change the positions.
  public mutating func summarized(_ ids: Set<UUID>, at date: Date) {
    pending.removeAll { ids.contains($0.id) }
    summarizedAt = date
    summary = .ready
  }
}
