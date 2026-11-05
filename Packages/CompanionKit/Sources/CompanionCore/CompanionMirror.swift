import Foundation

/// A simulator of the Mac on the phone, on a protocol of its own so that video never
/// holds up the sessions' channel. The phone opens one stream per request, each message of it a
/// `u8` length and a line: `list`, or `open <UDID>` followed by touches (`d|m|u x y`).
/// `list` answers a `u32` length and JSON; `open` answers `sim-bridge`'s frames as they come.
public enum CompanionMirror {
  public static let alpn = "vibe-manager/mirror/1"

  public struct Device: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public static func message(_ line: String) -> Data {
    let bytes = Data(line.utf8.prefix(255))
    return Data([UInt8(bytes.count)]) + bytes
  }

  /// What is waiting to be written to a slow network. Late frames are dropped, then everything up
  /// to the next key frame, since H.264 cannot decode across the hole. Touches never pass here.
  public struct Backlog: Sendable {
    public private(set) var pending: [Data] = []
    private var waitingForKey = false
    private let limit: Int

    public init(limit: Int = 2) {
      self.limit = limit
    }

    /// Returns whether the encoder must now be asked for a key frame.
    public mutating func add(_ frame: Data, isKey: Bool) -> Bool {
      if isKey {
        pending = [frame]
        waitingForKey = false
        return false
      }
      if waitingForKey { return false }
      if pending.count >= limit {
        pending = []
        waitingForKey = true
        return true
      }
      pending.append(frame)
      return false
    }

    public mutating func next() -> Data? {
      pending.isEmpty ? nil : pending.removeFirst()
    }
  }
}
