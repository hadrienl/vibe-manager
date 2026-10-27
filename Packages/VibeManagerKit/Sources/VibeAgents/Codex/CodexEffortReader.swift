import Foundation
import VibeApplication

/// Reads the reasoning effort a Codex conversation runs with (#411).
///
/// Codex says it itself: every turn opens with a `turn_context` record that names its model and
/// its `effort`, the last one being the level now in force — set at launch, or changed since in
/// the terminal's `/model`. Before the first turn, the conversation runs with `config.toml`'s
/// `model_reasoning_effort`, read without the rest of the file.
public struct CodexEffortReader: Sendable {
  /// A rollout is read from its end, a chunk at a time, and given up past this much: a turn whose
  /// output alone is larger leaves the level unknown rather than reading the whole file.
  static let chunkByteCount = 256 * 1024
  static let maximumBackwardByteCount = 16 * 1024 * 1024
  /// `config.toml` observed in the wild is a few kilobytes.
  static let maximumConfigByteCount = 1024 * 1024

  private let configURL: URL
  private let locator: AgentTranscriptLocator
  private let now: @Sendable () -> Date

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      configURL: CodexHome.directory(environment: environment)
        .appendingPathComponent("config.toml"),
      locator: AgentTranscriptLocator(
        codexSessions: CodexHome.sessionsDirectory(environment: environment)),
      now: now)
  }

  public init(
    configURL: URL, locator: AgentTranscriptLocator,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configURL = configURL
    self.locator = locator
    self.now = now
  }

  public func report(resumeIdentifier: String?, since: Date) -> AgentEffortReport {
    var report = configuredReport()
    guard let identifier = resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return report }
    // The latest rollout of the conversation: a resumed one may have been written to another.
    let rollouts = locator.codexRollouts(for: identifier, since: since, until: now())
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for rollout in rollouts.reversed() {
      if let turn = Self.lastTurnContext(of: rollout) {
        report.effort = turn.effort
        report.modelID = turn.modelID ?? report.modelID
        report.saidAt = turn.saidAt
        break
      }
    }
    return report
  }

  func configuredReport() -> AgentEffortReport {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path),
      let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumConfigByteCount,
      let text = try? String(contentsOf: configURL, encoding: .utf8)
    else { return AgentEffortReport() }
    return Self.configuredReport(toml: text)
  }

  /// The top-level `model` and `model_reasoning_effort` of a `config.toml`: the keys before the
  /// first table, as plain strings. Anything fancier is taken as not said.
  static func configuredReport(toml: String) -> AgentEffortReport {
    var report = AgentEffortReport()
    for line in toml.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { break }
      guard let equals = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
      var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
      value = value.trimmingCharacters(in: .whitespaces)
      guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
        value.last == quote
      else { continue }
      let string = String(value.dropFirst().dropLast())
      switch key {
      case "model": report.modelID = string.isEmpty ? nil : string
      case "model_reasoning_effort": report.configuredEffort = AgentEffortLevel.argument(string)
      default: continue
      }
    }
    return report
  }

  /// The last `turn_context` of a rollout, read from its end.
  static func lastTurnContext(of rollout: URL) -> AgentEffortReport? {
    guard let handle = try? FileHandle(forReadingFrom: rollout) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    var offset = end
    // What follows the first newline of the chunk read before: lines are only decoded whole.
    var carried = Data()
    while offset > 0, end - offset < UInt64(maximumBackwardByteCount) {
      let length = min(UInt64(chunkByteCount), offset)
      offset -= length
      guard (try? handle.seek(toOffset: offset)) != nil,
        let chunk = try? handle.read(upToCount: Int(length))
      else { return nil }
      var data = chunk + carried
      // The first line of the chunk may have begun earlier: it is kept for the next round.
      if offset > 0, let newline = data.firstIndex(of: 0x0A) {
        carried = data[data.startIndex..<newline]
        data = data[data.index(after: newline)...]
      } else {
        carried = Data()
      }
      if let report = lastTurnContext(in: data) { return report }
    }
    return nil
  }

  private static let marker = Data(#""turn_context""#.utf8)

  /// The last `turn_context` among whole lines. Only lines whose bytes hold the record's type are
  /// decoded, into a type that declares nothing but the model and the effort.
  static func lastTurnContext(in data: Data) -> AgentEffortReport? {
    for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
      guard let decoded = try? JSONDecoder().decode(TurnContextLine.self, from: Data(line)),
        decoded.type == "turn_context", let payload = decoded.payload
      else { continue }
      return AgentEffortReport(
        effort: payload.effort.flatMap(AgentEffortLevel.argument),
        modelID: payload.model.flatMap { $0.isEmpty ? nil : $0 },
        saidAt: decoded.timestamp.flatMap(TimestampParser().date))
    }
    return nil
  }

  private struct TurnContextLine: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
      let model: String?
      let effort: String?
    }
  }
}
