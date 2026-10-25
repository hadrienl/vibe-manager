import Foundation

/// The active channel's echo (#368): with the application in the foreground, the phone sends its
/// Mac a stamped frame every second over iroh, and the Mac sends it straight back. The round trip
/// is read on the phone's clock alone: the Mac's never enters it.
public enum CompanionEcho {
  /// The protocol's name in the QUIC handshake: a Mac endpoint accepts nothing else.
  public static let alpn = "vibe-companion/echo/1"
  /// One frame a second, while the channel is open.
  public static let interval: Duration = .seconds(1)
  /// The round trips the screen's statistics are read over: the last minute.
  public static let window = 60
}

/// What the phone sends and the Mac sends back unchanged: a sequence number and the phone's
/// monotonic clock when it left, in nanoseconds. Sixteen bytes, big-endian, read whole.
public struct CompanionEchoFrame: Hashable, Sendable {
  public static let size = 16

  public let sequence: UInt64
  /// The phone's monotonic clock, which stands still while the phone sleeps: the channel is closed
  /// by then.
  public let sentAt: UInt64

  public init(sequence: UInt64, sentAt: UInt64) {
    self.sequence = sequence
    self.sentAt = sentAt
  }

  public var encoded: Data {
    var bytes = Data(capacity: Self.size)
    for value in [sequence, sentAt] {
      withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
    return bytes
  }

  /// `nil` for anything but sixteen bytes.
  public init?(decoding data: Data) {
    guard data.count == Self.size else { return nil }
    let bytes = [UInt8](data)
    func word(at offset: Int) -> UInt64 {
      bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
    sequence = word(at: 0)
    sentAt = word(at: 8)
  }

  /// The round trip in milliseconds, when the frame comes back at `receivedAt` on the same clock.
  public func roundTrip(receivedAt: UInt64) -> Double? {
    guard receivedAt >= sentAt else { return nil }
    return Double(receivedAt - sentAt) / 1_000_000
  }
}

/// The last round trips, and what the screen reads of them.
public struct CompanionRoundTrips: Equatable, Sendable {
  public let capacity: Int
  /// Oldest first, in milliseconds.
  public private(set) var recent: [Double] = []

  public init(capacity: Int = CompanionEcho.window) {
    self.capacity = max(1, capacity)
  }

  public mutating func add(_ milliseconds: Double) {
    recent.append(milliseconds)
    if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
  }

  public var last: Double? { recent.last }
  public var p50: Double? { percentile(0.5) }
  public var p95: Double? { percentile(0.95) }

  /// By nearest rank: the smallest round trip that at least `fraction` of them do not exceed.
  public func percentile(_ fraction: Double) -> Double? {
    guard !recent.isEmpty else { return nil }
    let sorted = recent.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }
}

/// The way the channel's data goes: straight between the two devices, or through an iroh relay.
public enum CompanionPathKind: String, Hashable, Sendable {
  case direct
  case relay
  /// Connected, but no path selected yet.
  case unknown

  /// The selected path among iroh's, given as its two flags.
  public static func selected(among paths: [(isSelected: Bool, isRelay: Bool)]) -> Self {
    guard let path = paths.first(where: \.isSelected) else { return .unknown }
    return path.isRelay ? .relay : .direct
  }
}

/// How long the channel spent on each path, and how often it went from one to the other. Times
/// are seconds on any clock that only goes forward.
public struct CompanionPathLedger: Equatable, Sendable {
  /// The path now, `nil` while no channel is open: that time counts for neither.
  public private(set) var current: CompanionPathKind?
  /// A switch is from direct to relay or back, whatever unknown stretch lies between.
  public private(set) var switches = 0
  private var since: Double = 0
  private var lastKnown: CompanionPathKind?
  private var seconds: [CompanionPathKind: Double] = [:]

  public init() {}

  public mutating func note(_ kind: CompanionPathKind?, at time: Double) {
    settle(at: time)
    if let kind, kind != .unknown {
      if let lastKnown, lastKnown != kind { switches += 1 }
      lastKnown = kind
    }
    current = kind
  }

  /// The share of the time on a known path that went through a relay: `nil` before any.
  public func relayShare(at time: Double) -> Double? {
    var ledger = self
    ledger.settle(at: time)
    let relay = ledger.seconds[.relay, default: 0]
    let known = relay + ledger.seconds[.direct, default: 0]
    return known > 0 ? relay / known : nil
  }

  private mutating func settle(at time: Double) {
    if let current, time > since { seconds[current, default: 0] += time - since }
    since = max(since, time)
  }
}

/// One echo, as the export writes it.
public struct CompanionEchoSample: Hashable, Sendable {
  public let date: Date
  /// Which opening of the channel it belongs to: each return to the foreground opens another.
  public let session: Int
  public let sequence: UInt64
  public let roundTrip: Double
  public let path: CompanionPathKind
  /// How long that opening took, from the endpoint's creation to the connection, in milliseconds.
  public let setup: Double?

  public init(
    date: Date, session: Int, sequence: UInt64, roundTrip: Double, path: CompanionPathKind,
    setup: Double?
  ) {
    self.date = date
    self.session = session
    self.sequence = sequence
    self.roundTrip = roundTrip
    self.path = path
    self.setup = setup
  }
}

/// The samples as CSV, one line each, for the trial's annex.
public enum CompanionEchoCSV {
  public static let header = "date,session,sequence,rtt_ms,path,setup_ms"

  public static func text(_ samples: [CompanionEchoSample]) -> String {
    let dates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let lines = samples.map { sample in
      [
        sample.date.formatted(dates), "\(sample.session)", "\(sample.sequence)",
        milliseconds(sample.roundTrip), sample.path.rawValue,
        sample.setup.map(milliseconds) ?? "",
      ].joined(separator: ",")
    }
    return ([header] + lines).joined(separator: "\n") + "\n"
  }

  static func milliseconds(_ value: Double) -> String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
  }
}
