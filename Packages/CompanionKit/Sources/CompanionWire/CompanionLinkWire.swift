import CompanionCore
import Foundation

/// The link between the application and its companion agent (#347).
///
/// Framed as the terminal host's wire is (ADR 0017): a big-endian `u32` length, a `u8` kind and a
/// JSON payload, so that a capture reads by hand. Only control messages travel here: no terminal
/// byte ever does.
public enum CompanionLinkWire {
  public static let protocolVersion = 1
  /// A snapshot of every active session fits many times over; a corrupt length cannot make either
  /// side allocate a gigabyte.
  public static let maximumPayloadLength = 1 << 20
  static let headerLength = 5
  static let controlKind: UInt8 = 1
  /// In the private directory of the application's terminal host, which an isolated copy has of
  /// its own: so has its companion.
  public static let socketName = "companion-v\(protocolVersion).sock"
}

/// Everything either end says.
public enum CompanionLinkMessage: Codable, Equatable, Sendable {
  // The application to its agent.
  /// First, and again whenever the agent connects anew.
  case hello(protocolVersion: Int, installationID: String, version: String, buildLabel: String)
  /// The active sessions, whole: the agent works out what changed.
  case snapshot([CompanionSessionInfo])
  /// The application has the test: the agent writes its pong at once.
  case testAcknowledged(nonce: String, receivedAt: Date)

  // The agent to the application.
  case welcome(protocolVersion: Int)
  /// A test found in iCloud, for the application to acknowledge and show.
  case testReceived(CompanionPing)
}

enum CompanionLinkFrameError: Error, Equatable {
  case payloadTooLong(Int)
  case unknownKind(UInt8)
}

enum CompanionLinkFrame {
  /// These messages are plain values, and encoding them does not fail; if it ever did, the empty
  /// payload is a frame the other end cannot decode and ignores.
  static func encode(_ message: CompanionLinkMessage) -> [UInt8] {
    let payload = [UInt8]((try? JSONEncoder().encode(message)) ?? Data())
    let length = UInt32(payload.count)
    var bytes: [UInt8] = [
      UInt8(truncatingIfNeeded: length >> 24),
      UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8),
      UInt8(truncatingIfNeeded: length),
      CompanionLinkWire.controlKind,
    ]
    bytes.append(contentsOf: payload)
    return bytes
  }
}

/// Cuts a byte stream into messages. A read ends anywhere, so whatever is incomplete is kept for
/// the next one; a frame that does not decode is skipped, as the host's wire does.
struct CompanionLinkDecoder {
  private var buffer: [UInt8] = []

  mutating func append(_ bytes: some Collection<UInt8>) throws -> [CompanionLinkMessage] {
    buffer.append(contentsOf: bytes)
    var messages: [CompanionLinkMessage] = []
    var offset = 0
    while buffer.count - offset >= CompanionLinkWire.headerLength {
      let length =
        Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16
        | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
      guard length <= CompanionLinkWire.maximumPayloadLength else {
        throw CompanionLinkFrameError.payloadTooLong(length)
      }
      guard buffer[offset + 4] == CompanionLinkWire.controlKind else {
        throw CompanionLinkFrameError.unknownKind(buffer[offset + 4])
      }
      let start = offset + CompanionLinkWire.headerLength
      guard buffer.count - start >= length else { break }
      if let message = try? JSONDecoder().decode(
        CompanionLinkMessage.self, from: Data(buffer[start..<start + length]))
      {
        messages.append(message)
      }
      offset = start + length
    }
    buffer.removeFirst(offset)
    return messages
  }
}
