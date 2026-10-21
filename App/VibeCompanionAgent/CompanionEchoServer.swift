import CompanionCore
import Foundation
import IrohLib
import Security

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

  /// What a phone of the direct channel did (#399).
  enum RemoteEvent: Sendable {
    case opened(peer: String, endpointID: String)
    case received(peer: String, RemoteMessage)
    case closed(peer: String)
  }

  private let keyURL: URL
  private var endpoint: Endpoint?
  /// Whether a phone's endpoint is one of the user's: asked at each connection.
  private var authorize: @Sendable (String) async -> Bool = { _ in false }
  private var onRemote: @Sendable (RemoteEvent) -> Void = { _ in }
  /// Each phone's way back, by peer.
  private var remotes: [String: SendStream] = [:]
  private var remoteConnections: [String: Connection] = [:]
  private var remoteEndpoints: [String: String] = [:]
  private var nextPeer = 0
  private var relayLoop: Task<Void, Never>?
  private var acceptLoop: Task<Void, Never>?

  init(stateDirectory: URL) {
    keyURL = stateDirectory.appendingPathComponent("iroh-secret-key", isDirectory: false)
  }

  /// Binds the endpoint and serves the echo until `stop`. `onAddress` is called with the address
  /// as soon as the endpoint is bound, then each time its home relay changes.
  func start(
    authorize: @escaping @Sendable (String) async -> Bool,
    onRemote: @escaping @Sendable (RemoteEvent) -> Void,
    onAddress: @escaping @Sendable (Address) -> Void
  ) async {
    guard endpoint == nil else { return }
    self.authorize = authorize
    self.onRemote = onRemote
    let started = ContinuousClock.now
    let endpoint: Endpoint
    do {
      let key = try Self.secretKey(at: keyURL)
      endpoint = try await Endpoint.bind(
        options: CompanionIroh.options(
          secretKey: key, alpns: [CompanionIroh.alpn, CompanionIroh.remoteALPN]))
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
        Task.detached { await self.serve(incoming) }
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
  private func serve(_ incoming: Incoming) async {
    let connection: Connection
    do {
      connection = try await incoming.accept().connect()
    } catch {
      CompanionIroh.logger.error(
        "echo: handshake failed: \(CompanionIroh.describe(error), privacy: .public)")
      return
    }
    let remote = connection.remoteId().fmtShort()
    if connection.alpn() == CompanionIroh.remoteALPN {
      await serveRemote(connection)
      return
    }
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
        Task.detached { await Self.echo(stream) }
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

  // MARK: - Remote

  /// A phone of the direct channel (#399): admitted only when its endpoint is one the user's
  /// iCloud account lists, then one stream of frames each way until it goes.
  private func serveRemote(_ connection: Connection) async {
    let endpointID = connection.remoteId().description
    let short = connection.remoteId().fmtShort()
    guard await authorize(endpointID) else {
      CompanionIroh.logger.error(
        "remote: \(short, privacy: .public) is not a paired phone: refused")
      try? connection.close(errorCode: 2, reason: Data("not paired".utf8))
      return
    }
    let stream: BiStream
    do {
      stream = try await connection.acceptBi()
    } catch {
      CompanionIroh.logger.notice(
        "remote: \(short, privacy: .public) gone before a stream: \(CompanionIroh.describe(error), privacy: .public)"
      )
      return
    }
    nextPeer += 1
    let peer = "\(short)-\(nextPeer)"
    remotes[peer] = stream.send()
    remoteConnections[peer] = connection
    remoteEndpoints[peer] = endpointID
    onRemote(.opened(peer: peer, endpointID: endpointID))
    CompanionIroh.logger.notice(
      "remote: \(peer, privacy: .public) connected, \(CompanionIroh.describe(connection.paths()), privacy: .public)"
    )
    let receiving = stream.recv()
    var decoder = RemoteFrame.Decoder()
    do {
      while true {
        let header = try await receiving.readExact(size: 4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= RemoteFrame.maximumLength else { break }
        let body = length == 0 ? Data() : try await receiving.readExact(size: UInt32(length))
        for message in try decoder.append(header + body) {
          onRemote(.received(peer: peer, message))
        }
      }
    } catch {
      CompanionIroh.logger.notice(
        "remote: \(peer, privacy: .public) gone: \(connection.closeReason() ?? CompanionIroh.describe(error), privacy: .public)"
      )
    }
    remotes[peer] = nil
    remoteConnections[peer] = nil
    remoteEndpoints[peer] = nil
    onRemote(.closed(peer: peer))
  }

  /// To one phone; nothing if it went.
  func send(_ message: RemoteMessage, to peer: String) async {
    guard let sending = remotes[peer] else { return }
    do {
      try await sending.writeAll(buf: RemoteFrame.encode(message))
    } catch {
      CompanionIroh.logger.notice(
        "remote: \(peer, privacy: .public) unreachable: \(CompanionIroh.describe(error), privacy: .public)"
      )
    }
  }

  func drop(_ peer: String) {
    try? remoteConnections[peer]?.close(errorCode: 0, reason: Data("dropped".utf8))
  }

  /// Every connection of a phone no longer admitted.
  func drop(endpoint endpointID: String) {
    for (peer, endpoint) in remoteEndpoints where endpoint == endpointID {
      try? remoteConnections[peer]?.close(errorCode: 2, reason: Data("removed".utf8))
    }
  }

  // MARK: - Key

  /// The endpoint's secret key, kept in the login Keychain — one per installation, its folder
  /// naming it: what the phones dial must not change from one launch to the next. A key the trials
  /// left in a file is taken in once, and the file removed (#397).
  private static func secretKey(at url: URL) throws -> Data {
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: url.deletingLastPathComponent().path,
    ]
    var found: CFTypeRef?
    var query = item
    query[kSecReturnData as String] = true
    if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
      let key = found as? Data, key.count == 32
    {
      return key
    }
    let leftover = (try? Data(contentsOf: url)).flatMap { $0.count == 32 ? $0 : nil }
    let key = leftover ?? SecretKey.generate().toBytes()
    SecItemDelete(item as CFDictionary)
    var added = item
    added[kSecValueData as String] = key
    // No user presence asked: the agent runs without a window, and must answer the phones while
    // nobody is at the Mac. The key never leaves it, as the endpoints' secrets of the application.
    added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly  // NOSONAR
    added[kSecAttrLabel as String] = "Vibe Manager Companion"
    let status = SecItemAdd(added as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    if leftover != nil { try? FileManager.default.removeItem(at: url) }
    CompanionIroh.logger.notice(
      "echo: endpoint key \(leftover == nil ? "made" : "moved from its file", privacy: .public), kept in the Keychain"
    )
    return key
  }

  private static let keychainService = "eu.hadrien.VibeManager.CompanionAgent.iroh"

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = start.duration(to: .now).components
    return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
  }
}
