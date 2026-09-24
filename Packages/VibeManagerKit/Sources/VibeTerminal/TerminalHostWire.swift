import Foundation
import VibeApplication
import VibeDomain

/// The wire between the application and the terminal host (ADR 0016).
///
/// A frame is a big-endian `u32` length, a `u8` kind and a payload. Control messages are JSON, so
/// a capture can be read by hand the way `runtime.json` can; terminal bytes travel raw, behind the
/// sixteen bytes of the session they belong to, because encoding every keystroke and every burst of
/// output as JSON would cost a copy and a third more bytes for nothing.
enum TerminalHostWire {
  /// The frozen core. Every future application speaks it, so a host left running by an older
  /// build can always be reattached to; anything new is negotiated as a capability.
  static let protocolVersion = 1
  /// Large enough for a coalesced burst of output, small enough that a corrupt length cannot make
  /// either side allocate a gigabyte.
  static let maximumPayloadLength = 1 << 20
  /// How the history of a session is cut on its way to a client that attaches.
  static let historyChunkLength = 256 * 1_024
  static let headerLength = 5
}

enum TerminalHostFrameKind: UInt8, Sendable {
  case control = 1
  case input = 2
  case output = 3
}

struct TerminalHostFrame: Equatable, Sendable {
  let kind: TerminalHostFrameKind
  let payload: [UInt8]

  var encoded: [UInt8] {
    let length = UInt32(payload.count)
    var bytes: [UInt8] = [
      UInt8(truncatingIfNeeded: length >> 24),
      UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8),
      UInt8(truncatingIfNeeded: length),
      kind.rawValue,
    ]
    bytes.append(contentsOf: payload)
    return bytes
  }

  /// Terminal bytes for one session, cut into as many frames as the payload limit requires.
  ///
  /// The terminal reader coalesces up to 4 MiB of output at a time, and a paste can be as large:
  /// one frame for either would exceed what the other end accepts, and it would close the
  /// connection — which the host reads as its client crashing.
  static func terminalChunks(
    _ kind: TerminalHostFrameKind,
    session: SessionID,
    bytes: [UInt8]
  ) -> [TerminalHostFrame] {
    let limit = TerminalHostWire.maximumPayloadLength - 16
    guard bytes.count > limit else { return [terminal(kind, session: session, bytes: bytes)] }
    return stride(from: 0, to: bytes.count, by: limit).map { start in
      terminal(kind, session: session, bytes: Array(bytes[start..<min(start + limit, bytes.count)]))
    }
  }

  /// Terminal bytes for one session: its identifier, then the bytes as they were.
  static func terminal(
    _ kind: TerminalHostFrameKind,
    session: SessionID,
    bytes: [UInt8]
  ) -> TerminalHostFrame {
    var payload = [UInt8]()
    payload.reserveCapacity(16 + bytes.count)
    withUnsafeBytes(of: session.rawValue.uuid) { payload.append(contentsOf: $0) }
    payload.append(contentsOf: bytes)
    return TerminalHostFrame(kind: kind, payload: payload)
  }

  /// The session and the bytes of an `input` or `output` frame, `nil` when it is too short.
  var terminalBytes: (session: SessionID, bytes: [UInt8])? {
    guard kind != .control, payload.count >= 16 else { return nil }
    let uuid = payload.withUnsafeBytes { raw in
      raw.loadUnaligned(fromByteOffset: 0, as: uuid_t.self)
    }
    return (SessionID(rawValue: UUID(uuid: uuid)), Array(payload[16...]))
  }

  /// These messages are plain values, and encoding them does not fail; if it ever did, the empty
  /// payload is a frame the other end cannot decode and ignores.
  static func control<Message: Encodable>(_ message: Message) -> TerminalHostFrame {
    let data = (try? JSONEncoder().encode(message)) ?? Data()
    return TerminalHostFrame(kind: .control, payload: [UInt8](data))
  }

  func decode<Message: Decodable>(_ type: Message.Type) -> Message? {
    guard kind == .control else { return nil }
    return try? JSONDecoder().decode(type, from: Data(payload))
  }
}

enum TerminalHostFrameError: Error, Equatable {
  case payloadTooLong(Int)
  case unknownKind(UInt8)
}

/// Cuts a byte stream into frames. A read ends anywhere — in the middle of a header as easily as
/// in the middle of a payload — so whatever is incomplete is kept for the next one.
struct TerminalHostFrameDecoder {
  private var buffer: [UInt8] = []

  mutating func append(_ bytes: some Collection<UInt8>) throws -> [TerminalHostFrame] {
    buffer.append(contentsOf: bytes)
    var frames: [TerminalHostFrame] = []
    var offset = 0

    while buffer.count - offset >= TerminalHostWire.headerLength {
      let length =
        Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16
        | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
      guard length <= TerminalHostWire.maximumPayloadLength else {
        throw TerminalHostFrameError.payloadTooLong(length)
      }
      guard let kind = TerminalHostFrameKind(rawValue: buffer[offset + 4]) else {
        throw TerminalHostFrameError.unknownKind(buffer[offset + 4])
      }
      let start = offset + TerminalHostWire.headerLength
      guard buffer.count - start >= length else { break }
      frames.append(TerminalHostFrame(kind: kind, payload: Array(buffer[start..<start + length])))
      offset = start + length
    }

    buffer.removeFirst(offset)
    return frames
  }
}

// MARK: - Control messages

/// What the application asks. `request` is echoed by the reply, when there is one.
struct TerminalHostRequest: Codable, Equatable, Sendable {
  let request: UInt64
  let body: Body

  enum Body: Codable, Equatable, Sendable {
    /// `capabilities` names what this end speaks beyond the frozen core.
    case hello(protocolVersion: Int, build: String, capabilities: [String])
    case list
    case start(session: SessionID, spec: TerminalSpec)
    case attach(session: SessionID)
    case resize(session: SessionID, size: TerminalSize)
    /// Makes a full-screen program draw itself again, once a reattached view knows its size.
    case redraw(session: SessionID)
    case stop(session: SessionID, gracePeriodMilliseconds: Int)
    case kill(session: SessionID)
    /// Forgets a session that has ended and whose last output has been read.
    case release(session: SessionID)
    case goodbye(keepRunning: Bool)
  }
}

/// Why a host would not serve a client. None of these says the host is not ours: it proved it is,
/// or the client would not have sent a byte.
enum TerminalHostRefusal: String, Codable, Equatable, Sendable {
  /// Another copy of the application is attached.
  case otherClient
  /// The client speaks a protocol this host does not.
  case incompatible
}

struct HostedSessionRecord: Codable, Equatable, Sendable {
  let session: SessionID
  let state: TerminalProcessState
  let endedAt: Date?
}

/// What the host says: a reply to a request, or news about a session nobody asked for.
struct TerminalHostMessage: Codable, Equatable, Sendable {
  let request: UInt64?
  let body: Body

  enum Body: Codable, Equatable, Sendable {
    /// `startedAt` is the instant the kernel says the host started, the one the application
    /// confronts later to tell this host from a process that inherited its pid.
    case welcome(
      protocolVersion: Int, build: String, capabilities: [String], processIdentifier: Int32,
      startedAt: Date?)
    case refused(reason: String, refusal: TerminalHostRefusal)
    case sessions([HostedSessionRecord])
    case started(processIdentifier: Int32)
    case startFailed(TerminalError)
    /// Sent once the history has been, so that "attached" means "everything before now is here".
    case attached(session: SessionID, state: TerminalProcessState, droppedByteCount: Int)
    case stopped(state: TerminalProcessState)
    case done
    case unknownSession
    case state(session: SessionID, state: TerminalProcessState, endedAt: Date?)
    case truncated(session: SessionID, droppedByteCount: Int)
  }
}
