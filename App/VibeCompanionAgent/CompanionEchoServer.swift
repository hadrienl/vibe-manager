import CompanionCore
import Foundation
import IrohLib

/// The Mac's end of the active channel (#368): an iroh endpoint that sends back every echo frame
/// the phone sends, at once.
///
/// Its key is kept in the agent's folder, so that its identifier — what the phone dials — stays
/// the same from one launch to the next. The agent writes that identifier, and the relay the
/// endpoint calls home, in its `Mac` record: the only rendezvous, with nothing to exchange at each
/// connection. Any endpoint that knows the identifier may connect and get its frames back: an echo
/// leaks nothing, but a real protocol would check the phone's key first.
actor CompanionEchoServer {
  /// What the phone needs to dial this Mac.
  struct Address: Equatable, Sendable {
    let endpointID: String
    let relayURL: String?
  }

  /// How often the home relay is read again: it changes when the Mac's network does, rarely.
  private static let relayCheck: Duration = .seconds(30)

  private let keyURL: URL
  private var endpoint: Endpoint?
  private var relayLoop: Task<Void, Never>?
  private var acceptLoop: Task<Void, Never>?

  init(stateDirectory: URL) {
    keyURL = stateDirectory.appendingPathComponent("iroh-secret-key", isDirectory: false)
  }

  /// Binds the endpoint and serves the echo until `stop`. `onAddress` is called with the address
  /// as soon as the endpoint is bound, then each time its home relay changes.
  func start(onAddress: @escaping @Sendable (Address) -> Void) async {
    guard endpoint == nil else { return }
    let started = ContinuousClock.now
    let endpoint: Endpoint
    do {
      let key = try Self.secretKey(at: keyURL)
      endpoint = try await Endpoint.bind(
        options: CompanionIroh.options(secretKey: key, alpns: [CompanionIroh.alpn]))
    } catch {
      CompanionIroh.logger.error(
        "echo: no endpoint: \(CompanionIroh.describe(error), privacy: .public)")
      return
    }
    self.endpoint = endpoint
    let id = endpoint.id().description
    CompanionIroh.logger.notice(
      "echo: endpoint \(id, privacy: .public) bound on \(endpoint.boundSockets().joined(separator: " "), privacy: .public) in \(Self.milliseconds(since: started), privacy: .public) ms"
    )
    onAddress(Address(endpointID: id, relayURL: endpoint.addr().relayUrl()))
    relayLoop = Task.detached {
      await endpoint.online()
      var relay = endpoint.addr().relayUrl()
      CompanionIroh.logger.notice(
        "echo: online through \(relay ?? "no relay", privacy: .public) after \(Self.milliseconds(since: started), privacy: .public) ms"
      )
      onAddress(Address(endpointID: id, relayURL: relay))
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.relayCheck)
        let now = endpoint.addr().relayUrl()
        guard now != relay, !Task.isCancelled else { continue }
        CompanionIroh.logger.notice("echo: home relay now \(now ?? "none", privacy: .public)")
        relay = now
        onAddress(Address(endpointID: id, relayURL: now))
      }
    }
    acceptLoop = Task.detached {
      while let incoming = await endpoint.acceptNext() {
        Task.detached { await Self.serve(incoming) }
      }
      CompanionIroh.logger.notice("echo: endpoint closed, no more connections")
    }
  }

  func stop() async {
    acceptLoop?.cancel()
    relayLoop?.cancel()
    try? await endpoint?.close()
    endpoint = nil
  }

  // MARK: - Echo

  /// One phone's connection: every bidirectional stream it opens is echoed, until it closes.
  private static func serve(_ incoming: Incoming) async {
    let connection: Connection
    do {
      connection = try await incoming.accept().connect()
    } catch {
      CompanionIroh.logger.error(
        "echo: handshake failed: \(CompanionIroh.describe(error), privacy: .public)")
      return
    }
    let remote = connection.remoteId().fmtShort()
    guard connection.alpn() == CompanionIroh.alpn else {
      CompanionIroh.logger.error("echo: \(remote, privacy: .public) asked another protocol")
      try? connection.close(errorCode: 1, reason: Data("unknown protocol".utf8))
      return
    }
    CompanionIroh.logger.notice(
      "echo: \(remote, privacy: .public) connected, \(CompanionIroh.describe(connection.paths()), privacy: .public)"
    )
    // The path the phone's data takes, journaled each time it changes: read every second.
    let pathLog = Task.detached {
      var selection = CompanionIroh.selection(connection.paths())
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        let paths = connection.paths()
        guard CompanionIroh.selection(paths) != selection else { continue }
        selection = CompanionIroh.selection(paths)
        CompanionIroh.logger.notice(
          "echo: \(remote, privacy: .public) path: \(CompanionIroh.describe(paths), privacy: .public)"
        )
      }
    }
    do {
      while true {
        let stream = try await connection.acceptBi()
        Task.detached { await echo(stream) }
      }
    } catch {
      CompanionIroh.logger.notice(
        "echo: \(remote, privacy: .public) gone: \(connection.closeReason() ?? CompanionIroh.describe(error), privacy: .public)"
      )
    }
    pathLog.cancel()
  }

  /// Sends each frame back as it came, whole, until the phone finishes the stream.
  private static func echo(_ stream: BiStream) async {
    let receiving = stream.recv()
    let sending = stream.send()
    do {
      while true {
        let frame = try await receiving.readExact(size: UInt32(CompanionEchoFrame.size))
        try await sending.writeAll(buf: frame)
      }
    } catch {
      try? await sending.finish()
    }
  }

  // MARK: - Key

  /// The endpoint's secret key: read from the agent's folder, or made and written there the first
  /// time, readable by the user alone.
  private static func secretKey(at url: URL) throws -> Data {
    if let key = try? Data(contentsOf: url), key.count == 32 { return key }
    let key = SecretKey.generate().toBytes()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try key.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    CompanionIroh.logger.notice("echo: new endpoint key written")
    return key
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = start.duration(to: .now).components
    return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
  }
}
