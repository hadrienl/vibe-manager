import CompanionCore
import Foundation
import IrohLib
import Observation

/// The active channel to the Mac (#368), open while the application is in the foreground: an iroh
/// connection to the endpoint the Mac publishes in its record, and an echo every second over it.
///
/// Direct first — on the same network, or through a punched hole — and n0's public relays only
/// when that fails; CloudKit stays the way when the channel cannot open. Closed when the
/// application leaves the foreground, endpoint included: iOS breaks its UDP socket during a
/// suspension (iroh #4289), so each return builds a new one.
@Observable
@MainActor
final class CompanionChannel {
  enum Phase: Equatable {
    case closed
    /// The Mac shown has not published an endpoint: an agent without iroh, or not started yet.
    case noEndpoint
    case connecting
    case connected
    case failed(String)
  }

  /// How long a connection may take before the channel gives up and CloudKit is left alone.
  private static let connectLimit: Duration = .seconds(20)

  private(set) var phase = Phase.closed
  private(set) var path = CompanionPathKind.unknown
  /// The selected path's other end: an `ip:port`, or the relay's URL.
  private(set) var pathAddress: String?
  /// From the endpoint's creation to the connection, for the last opening, in milliseconds.
  private(set) var setup: Double?
  private(set) var roundTrips = CompanionRoundTrips()
  private(set) var ledger = CompanionPathLedger()
  private(set) var samples: [CompanionEchoSample] = []
  /// Which opening is current: anything an earlier one hands back late is dropped.
  private(set) var session = 0
  /// The endpoint the channel dials, short.
  private(set) var remote: String?
  /// What the screen reads the relay's share against.
  private(set) var now = ContinuousClock.now

  private let origin = ContinuousClock.now
  private var endpoint: Endpoint?
  private var connection: Connection?
  private var tasks: [Task<Void, Never>] = []

  var relayShare: Double? { ledger.relayShare(at: seconds(now)) }

  /// Opens the channel to `mac`, closing any other first.
  func open(to mac: CompanionMac?) {
    close()
    guard let mac, let endpointID = mac.irohEndpointID else {
      phase = .noEndpoint
      return
    }
    let session = self.session
    phase = .connecting
    remote = String(endpointID.prefix(10))
    CompanionIroh.logger.notice(
      "channel \(session, privacy: .public): dialing \(endpointID, privacy: .public) via \(mac.irohRelayURL ?? "no relay", privacy: .public)"
    )
    tasks.append(
      Task { await connect(endpointID: endpointID, relay: mac.irohRelayURL, session: session) })
    tasks.append(
      Task {
        try? await Task.sleep(for: Self.connectLimit)
        guard self.session == session, phase == .connecting else { return }
        fail(
          String(localized: "no connection in \(Self.connectLimit.components.seconds) s"),
          session: session)
      })
  }

  /// Closes the connection and the endpoint; what was measured stays.
  func close() {
    session += 1
    tasks.forEach { $0.cancel() }
    tasks = []
    let (endpoint, connection) = (endpoint, connection)
    self.endpoint = nil
    self.connection = nil
    if endpoint != nil {
      CompanionIroh.logger.notice("channel \(self.session - 1, privacy: .public): closed")
    }
    Task.detached {
      try? connection?.close(errorCode: 0, reason: Data("background".utf8))
      try? await endpoint?.close()
    }
    if phase == .connecting || phase == .connected { phase = .closed }
    path = .unknown
    pathAddress = nil
    tick()
    ledger.note(nil, at: seconds(now))
  }

  /// The screen's clock, once a second while the channel is up.
  func tick() {
    now = .now
  }

  var csv: String { CompanionEchoCSV.text(samples) }

  // MARK: - Connection

  private func connect(endpointID: String, relay: String?, session: Int) async {
    let started = ContinuousClock.now
    do {
      let endpoint = try await Endpoint.bind(options: CompanionIroh.options())
      guard self.session == session else {
        try? await endpoint.close()
        return
      }
      self.endpoint = endpoint
      let address = EndpointAddr(
        id: try EndpointId.fromString(s: endpointID), relayUrl: relay, addresses: [])
      let connection = try await endpoint.connect(addr: address, alpn: CompanionIroh.alpn)
      guard self.session == session else { return }
      self.connection = connection
      let elapsed = started.duration(to: .now)
      setup = Self.milliseconds(elapsed)
      phase = .connected
      apply(connection.paths(), session: session)
      CompanionIroh.logger.notice(
        "channel \(session, privacy: .public): connected in \(Int(self.setup ?? 0), privacy: .public) ms, \(CompanionIroh.describe(connection.paths()), privacy: .public)"
      )
      let stream = try await connection.openBi()
      guard self.session == session else { return }
      // The selected path, read every second: iroh's watchers cannot be used (CompanionIroh).
      tasks.append(
        Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            self?.apply(connection.paths(), session: session)
          }
        })
      tasks.append(Task.detached { [weak self] in await self?.send(on: stream, session: session) })
      tasks.append(
        Task.detached { [weak self] in await self?.receive(on: stream, session: session) })
    } catch {
      fail(CompanionIroh.describe(error), session: session)
    }
  }

  /// A frame a second, stamped with the monotonic clock when it leaves.
  private nonisolated func send(on stream: BiStream, session: Int) async {
    let sending = stream.send()
    var sequence: UInt64 = 0
    do {
      while !Task.isCancelled {
        let frame = CompanionEchoFrame(
          sequence: sequence, sentAt: DispatchTime.now().uptimeNanoseconds)
        try await sending.writeAll(buf: frame.encoded)
        sequence += 1
        try await Task.sleep(for: CompanionEcho.interval)
      }
    } catch is CancellationError {
    } catch {
      await fail(CompanionIroh.describe(error), session: session)
    }
  }

  /// Each frame back, timed as soon as it is read, off the main actor.
  private nonisolated func receive(on stream: BiStream, session: Int) async {
    let receiving = stream.recv()
    do {
      while !Task.isCancelled {
        let data = try await receiving.readExact(size: UInt32(CompanionEchoFrame.size))
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        guard let frame = CompanionEchoFrame(decoding: data),
          let roundTrip = frame.roundTrip(receivedAt: receivedAt)
        else { continue }
        await record(frame.sequence, roundTrip: roundTrip, session: session)
      }
    } catch {
      await fail(CompanionIroh.describe(error), session: session)
    }
  }

  private func record(_ sequence: UInt64, roundTrip: Double, session: Int) {
    guard self.session == session else { return }
    roundTrips.add(roundTrip)
    samples.append(
      CompanionEchoSample(
        date: Date(), session: session, sequence: sequence, roundTrip: roundTrip, path: path,
        setup: setup))
    tick()
  }

  private func apply(_ paths: [PathSnapshot], session: Int) {
    guard self.session == session, phase == .connected else { return }
    let kind = CompanionIroh.pathKind(paths)
    let address = paths.first(where: \.isSelected)?.remoteAddr
    if kind != path || address != pathAddress {
      CompanionIroh.logger.notice(
        "channel \(session, privacy: .public): path \(CompanionIroh.describe(paths), privacy: .public)"
      )
    }
    tick()
    let switches = ledger.switches
    ledger.note(kind, at: seconds(now))
    if ledger.switches != switches {
      CompanionIroh.logger.notice(
        "channel \(session, privacy: .public): switch \(self.ledger.switches, privacy: .public), now \(kind.rawValue, privacy: .public)"
      )
    }
    path = kind
    pathAddress = address
  }

  private func fail(_ reason: String, session: Int) {
    guard self.session == session, phase == .connecting || phase == .connected else { return }
    CompanionIroh.logger.error(
      "channel \(session, privacy: .public): failed: \(reason, privacy: .public)")
    close()
    phase = .failed(reason)
  }

  private func seconds(_ instant: ContinuousClock.Instant) -> Double {
    Self.milliseconds(origin.duration(to: instant)) / 1000
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
  }
}
