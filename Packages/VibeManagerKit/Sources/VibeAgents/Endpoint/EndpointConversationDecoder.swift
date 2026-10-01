import Foundation
import VibeApplication
import VibeDomain

/// The harness's transcript of an endpoint session, with what the gateway saw put in its place
/// (#107 §4): the steps an agent on the server ran, which the harness never learns of as calls,
/// and the waits before another attempt.
///
/// The gateway's journal is read again whenever the transcript is, and its records are placed by
/// date among the transcript's entries: a step comes right before the answer it led to.
final class EndpointConversationDecoder: ConversationDecoding {
  private let inner: any ConversationDecoding
  private let journal: URL
  private var records: [GatewayStepRecord] = []
  private var journalDate: Date?

  init(inner: any ConversationDecoding, journal: URL) {
    self.inner = inner
    self.journal = journal
  }

  func consume(_ record: TranscriptRecord) {
    inner.consume(record)
  }

  var entries: [ConversationEntry] {
    refresh()
    let own = inner.entries
    guard !records.isEmpty else { return own }
    let added = records.enumerated().map { Self.entry(for: $0.element, index: $0.offset) }
    return Self.merged(own, added)
  }

  private func refresh() {
    let date =
      (try? FileManager.default.attributesOfItem(atPath: journal.path))?[.modificationDate]
      as? Date
    guard date != journalDate else { return }
    journalDate = date
    guard let data = try? Data(contentsOf: journal) else {
      records = []
      return
    }
    records = data.split(separator: UInt8(ascii: "\n")).compactMap {
      try? GatewayStepRecord.decoder.decode(GatewayStepRecord.self, from: Data($0))
    }
  }

  /// Each record before the first entry written after it; entries without a date keep their
  /// place, and a record newer than everything comes last.
  static func merged(_ entries: [ConversationEntry], _ added: [ConversationEntry])
    -> [ConversationEntry]
  {
    var result: [ConversationEntry] = []
    var pending = added[...]
    for entry in entries {
      if let date = entry.date {
        while let next = pending.first, let when = next.date, when <= date {
          result.append(next)
          pending = pending.dropFirst()
        }
      }
      result.append(entry)
    }
    result.append(contentsOf: pending)
    return result
  }

  static func entry(for record: GatewayStepRecord, index: Int) -> ConversationEntry {
    let id = "gateway:\(index)"
    switch record.kind {
    case .step:
      var parameters: [ToolParameter] = []
      if let input = record.input, !input.isEmpty { parameters.append(ToolParameter(.arguments, input)) }
      return ConversationEntry(
        id: id, date: record.date,
        content: .tool(
          ToolCall(
            callID: id, kind: .mcp(server: serverName, tool: record.name ?? "step"),
            state: .succeeded, parameters: parameters,
            output: record.output.map { ToolOutput(text: $0) })))
    case .retry:
      return ConversationEntry(
        id: id, date: record.date, content: .notice(.information(retrySentence(record))))
    }
  }

  /// How a step of an agent on the server is labelled among the tools.
  static let serverName = "server"

  static func retrySentence(_ record: GatewayStepRecord) -> String {
    let seconds = Int((record.delaySeconds ?? 0).rounded(.up))
    let attempt = record.attempt ?? 2
    let maximum = record.maximum ?? attempt
    switch record.failure {
    case "rateLimited":
      return String(
        localized:
          "The endpoint limits its rate. Attempt \(attempt) of \(maximum) in \(seconds) s.",
        bundle: .module)
    case "network", "timeout":
      return String(
        localized:
          "The endpoint did not answer. Attempt \(attempt) of \(maximum) in \(seconds) s.",
        bundle: .module)
    default:
      return String(
        localized:
          "The endpoint failed to answer. Attempt \(attempt) of \(maximum) in \(seconds) s.",
        bundle: .module)
    }
  }
}
