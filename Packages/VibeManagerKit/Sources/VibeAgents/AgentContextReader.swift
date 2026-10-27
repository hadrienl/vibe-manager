import Foundation
import VibeApplication
import VibeDomain

/// The context window of the current conversation (#407), read with the same guarantees as its
/// usage: a line is decoded only when its bytes hold a key, into types that declare nothing but
/// counters, a model, a date and the markers of a compaction.
///
/// Claude Code: the context of an answer is its input with the cache, read and written; the
/// lines of a sub-agent (`isSidechain`) and those the CLI writes itself (`<synthetic>`) are left
/// out. Its window is in no transcript: none is shown, but an endpoint's. A compaction is a
/// `compact_boundary` line, with the context before it.
///
/// Codex: the context is `last_token_usage.total_tokens` of the last `token_count`, the window its
/// `model_context_window`; a compaction is a `compacted` line, the context before it the last
/// one read.
extension AgentUsageReader: ContextWindowReading {
  public func readContext(
    of conversation: SessionAgentConfiguration, session: WorkSession, from file: ContextWindowFile?
  ) async -> ContextWindowFile? {
    guard
      let identifier = conversation.resumeIdentifier?.trimmingCharacters(
        in: .whitespacesAndNewlines), !identifier.isEmpty
    else { return nil }
    let candidates: [URL]
    let isCodex: Bool
    switch conversation.transcriptProviderID {
    case ClaudeCodeAgentProvider.id.rawValue:
      candidates = locator.claudeTranscripts(for: identifier).filter {
        $0.lastPathComponent == "\(identifier).jsonl"
      }
      isCodex = false
    case CodexAgentProvider.id.rawValue:
      candidates = locator.codexRollouts(for: identifier, since: session.createdAt, until: now())
      isCodex = true
    default:
      return nil
    }
    guard let url = candidates.max(by: { Self.modified($0) < Self.modified($1) }) else {
      return nil
    }
    return Self.readContext(url, from: file ?? ContextWindowFile(), isCodex: isCodex, now: now())
  }

  private static func modified(_ url: URL) -> Date {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
      ?? .distantPast
  }

  static func readContext(_ url: URL, from entry: ContextWindowFile, isCodex: Bool, now: Date)
    -> ContextWindowFile
  {
    var file = entry
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return file
    }
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    if size < file.offset || (file.inode != nil && inode != nil && file.inode != inode) {
      file = ContextWindowFile()
    }
    file.inode = inode
    guard size > file.offset, let handle = try? FileHandle(forReadingFrom: url) else {
      return file
    }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: file.offset)) != nil else { return file }
    let data = (try? handle.readToEnd()) ?? Data()
    // Only whole lines: the CLI may be in the middle of writing the last one.
    guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return file }
    let complete = data[data.startIndex...lastNewline]
    file.offset += UInt64(complete.count)
    let timestamps = TimestampParser()
    for line in complete.split(separator: UInt8(ascii: "\n")) {
      if isCodex {
        readCodexContext(line: Data(line), into: &file, now: now, timestamps: timestamps)
      } else {
        readClaudeContext(line: Data(line), into: &file, now: now, timestamps: timestamps)
      }
    }
    return file
  }

  // MARK: - Claude Code

  static let claudeCompactionMarker = Data(#""compact_boundary""#.utf8)

  static func readClaudeContext(
    line: Data, into file: inout ContextWindowFile, now: Date, timestamps: TimestampParser
  ) {
    guard line.range(of: claudeMarker) != nil || line.range(of: claudeCompactionMarker) != nil,
      let decoded = try? JSONDecoder().decode(ClaudeContextLine.self, from: line),
      decoded.isSidechain != true
    else { return }
    let date = decoded.timestamp.flatMap(timestamps.date) ?? now
    if decoded.type == "system", decoded.subtype == "compact_boundary" {
      file.compaction = .init(date: date, tokensBefore: decoded.compactMetadata?.preTokens)
      return
    }
    guard decoded.type == "assistant", let message = decoded.message,
      message.model != "<synthetic>", let usage = message.usage
    else { return }
    let used = (usage.input ?? 0) + (usage.cacheWrite ?? 0) + (usage.cacheRead ?? 0)
    file.usage = ContextWindowUsage(
      usedTokens: used, measuredAt: date,
      lastCompaction: file.compaction ?? file.usage?.lastCompaction)
    file.compaction = nil
  }

  // MARK: - Codex

  static let codexCompactionMarker = Data(#""type":"compacted""#.utf8)

  static func readCodexContext(
    line: Data, into file: inout ContextWindowFile, now: Date, timestamps: TimestampParser
  ) {
    let isCompaction = line.range(of: codexCompactionMarker) != nil
    guard isCompaction || line.range(of: Data(#""token_count""#.utf8)) != nil,
      let decoded = try? JSONDecoder().decode(CodexContextLine.self, from: line)
    else { return }
    let date = decoded.timestamp.flatMap(timestamps.date) ?? now
    if decoded.type == "compacted" {
      file.compaction = .init(date: date, tokensBefore: file.usage?.usedTokens)
      return
    }
    guard decoded.type == "event_msg", decoded.payload?.type == "token_count",
      let info = decoded.payload?.info, let last = info.lastTokenUsage
    else { return }
    let used = last.total ?? ((last.input ?? 0) + (last.output ?? 0))
    file.usage = ContextWindowUsage(
      usedTokens: used, windowSize: info.modelContextWindow, measuredAt: date,
      source: info.modelContextWindow == nil ? nil : .reportedByCLI,
      lastCompaction: file.compaction ?? file.usage?.lastCompaction, countsLikeCodex: true)
    file.compaction = nil
  }
}

// MARK: - What is decoded, and nothing else

/// A Claude Code transcript line, reduced to what the context needs. No content field is
/// declared, so none can be decoded, kept or logged.
struct ClaudeContextLine: Decodable {
  let type: String?
  let subtype: String?
  let timestamp: String?
  let isSidechain: Bool?
  let message: Message?
  let compactMetadata: CompactMetadata?

  struct Message: Decodable {
    let model: String?
    let usage: ClaudeUsageLine.Usage?
  }

  struct CompactMetadata: Decodable {
    let preTokens: Int?
  }
}

/// A Codex rollout line, reduced the same way: the payload of a compaction holds the history it
/// replaced, and is never decoded.
struct CodexContextLine: Decodable {
  let type: String?
  let timestamp: String?
  let payload: Payload?

  enum CodingKeys: String, CodingKey {
    case type, timestamp, payload
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    payload =
      type == "event_msg" ? try container.decodeIfPresent(Payload.self, forKey: .payload) : nil
  }

  struct Payload: Decodable {
    let type: String?
    let info: CodexUsageLine.Info?
  }
}
