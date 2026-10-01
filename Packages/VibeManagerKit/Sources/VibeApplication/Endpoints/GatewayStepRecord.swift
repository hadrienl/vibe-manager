import Foundation
import VibeDomain

/// What the gateway saw happen in a session that its harness's transcript cannot say (#107 §4):
/// the steps an agent on the server ran by itself, and the waits before another attempt. One JSON
/// line each, in `<gateway>/steps/<session>.jsonl`, read by the conversation view.
///
/// Written by the gateway, which alone sees them. The inputs and outputs of steps are cut short:
/// the conversation shows what a step did, not everything it read.
public struct GatewayStepRecord: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case step
    case retry
  }

  public var date: Date
  public var kind: Kind
  public var name: String?
  public var input: String?
  public var output: String?
  public var attempt: Int?
  public var maximum: Int?
  public var delaySeconds: Double?
  public var failure: String?
  public var status: Int?

  public init(
    date: Date, kind: Kind, name: String? = nil, input: String? = nil, output: String? = nil,
    attempt: Int? = nil, maximum: Int? = nil, delaySeconds: Double? = nil, failure: String? = nil,
    status: Int? = nil
  ) {
    self.date = date
    self.kind = kind
    self.name = name
    self.input = input
    self.output = output
    self.attempt = attempt
    self.maximum = maximum
    self.delaySeconds = delaySeconds
    self.failure = failure
    self.status = status
  }

  public static let limit = 2_000

  public static func cut(_ text: String?) -> String? {
    guard let text else { return nil }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
  }

  public static func file(for session: SessionID, in directory: URL) -> URL {
    directory.appendingPathComponent("steps", isDirectory: true)
      .appendingPathComponent("\(session.rawValue.uuidString).jsonl")
  }

  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
