import AppKit
import CompanionCore
import CompanionWire
import Darwin
import Foundation
import VibeApplication
import os

/// The application's side of the mobile companion (#347): it starts the companion agent embedded in
/// the bundle, hands it the active sessions and takes the tests it finds.
///
/// The agent is a process of its own — `Contents/Helpers/Vibe Manager Companion.app` — because the
/// iCloud entitlement, and the provisioning profile checked at every launch that comes with it,
/// must stay out of the application's binary, which is also the terminal host and the gateway
/// (ADR 0021). The application listens on a socket of its terminal host's private directory, and
/// the agent connects: each demands of the other the same team and the expected identifier. When
/// the application goes, the socket closes, and the agent writes the Mac offline and quits.
public actor CompanionLink: CompanionPublishing {
  public struct Configuration: Sendable {
    public var socketPath: String
    /// Makes the socket's private directory, before it is listened on.
    public var prepare: @Sendable () throws -> Void
    /// `Vibe Manager Companion.app`.
    public var agentBundle: URL
    /// Where the agent keeps its sync engine's state and the records it knows.
    public var stateDirectory: URL
    /// This copy of the application, on an iCloud account other copies share.
    public var installationID: String
    public var version: String
    public var buildLabel: String
    public var verifier: any CompanionPeerVerifying

    public init(
      socketPath: String, prepare: @escaping @Sendable () throws -> Void, agentBundle: URL,
      stateDirectory: URL, installationID: String, version: String, buildLabel: String,
      verifier: any CompanionPeerVerifying = CodeSigningCompanionPeerVerifier(
        peerIdentifier: CompanionLink.agentIdentifier)
    ) {
      self.socketPath = socketPath
      self.prepare = prepare
      self.agentBundle = agentBundle
      self.stateDirectory = stateDirectory
      self.installationID = installationID
      self.version = version
      self.buildLabel = buildLabel
      self.verifier = verifier
    }
  }

  public static let agentIdentifier = "eu.hadrien.VibeManager.CompanionAgent"
  /// In the terminal host's private directory (`TerminalHostLocation`), beside its socket.
  public static let socketName = CompanionLinkWire.socketName
  /// An agent that left while the application runs — a crash — is started again, a few times.
  private static let relaunchLimit = 3
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "link")

  private let configuration: Configuration
  private let diagnostics: Diagnostics
  private var listener: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connection: CompanionLinkConnection?
  private var latest: CompanionSnapshot?
  private var onTest: (@Sendable (CompanionTest) async -> Void)?
  private var launches = 0
  private var isStopping = false

  public init(configuration: Configuration, diagnostics: Diagnostics) {
    self.configuration = configuration
    self.diagnostics = diagnostics
  }

  /// Listens, then starts the agent. `onTest` is given each test the agent hands over.
  public func start(onTest: @escaping @Sendable (CompanionTest) async -> Void) async {
    self.onTest = onTest
    do {
      try configuration.prepare()
      unlink(configuration.socketPath)
      listener = try CompanionSocket.listen(at: configuration.socketPath)
    } catch {
      diagnostics.record(.lifecycle, .error, "companion.listenFailed")
      return
    }
    let source = DispatchSource.makeReadSource(
      fileDescriptor: listener, queue: DispatchQueue(label: "eu.hadrien.VibeManager.companion"))
    source.setEventHandler { [weak self] in
      Task { await self?.acceptPending() }
    }
    source.resume()
    acceptSource = source
    await launchAgent()
  }

  /// The application quits: the agent sees its socket close, writes the Mac offline, and goes.
  public func stop() {
    isStopping = true
    connection?.close()
    connection = nil
    acceptSource?.cancel()
    acceptSource = nil
    if listener >= 0 {
      close(listener)
      listener = -1
      unlink(configuration.socketPath)
    }
  }

  // MARK: - CompanionPublishing

  public func publish(_ snapshot: CompanionSnapshot) {
    latest = snapshot
    let state = connection == nil ? "kept until the agent connects" : "sent"
    Self.logger.notice(
      "snapshot of \(snapshot.sessions.count, privacy: .public) session(s), \(state, privacy: .public)"
    )
    connection?.send(.snapshot(Self.wire(snapshot)))
  }

  public func acknowledge(_ test: CompanionTest, receivedAt: Date) {
    let state = connection == nil ? "no agent connected, lost" : "sent"
    Self.logger.notice(
      "acknowledgement of test \(test.nonce, privacy: .public): \(state, privacy: .public)")
    connection?.send(.testAcknowledged(nonce: test.nonce, receivedAt: receivedAt))
  }

  // MARK: - Agent

  private func launchAgent() async {
    guard !isStopping, launches < Self.relaunchLimit else { return }
    launches += 1
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    // A copy of the application has an agent of its own, from the same bundle maybe: never the
    // one already running for another copy.
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [
      CompanionAgentArguments.link, self.configuration.socketPath,
      CompanionAgentArguments.state, self.configuration.stateDirectory.path,
    ]
    // Through Launch Services rather than spawned: the agent is an application, the one that
    // receives CloudKit's pushes, and it is registered as such.
    do {
      _ = try await NSWorkspace.shared.openApplication(
        at: self.configuration.agentBundle, configuration: configuration)
      diagnostics.record(.lifecycle, .notice, "companion.agentLaunched")
    } catch {
      diagnostics.record(.lifecycle, .error, "companion.agentLaunchFailed")
      Self.logger.error("agent not launched: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func acceptPending() {
    guard listener >= 0 else { return }
    let descriptor = accept(listener, nil, nil)
    guard descriptor >= 0 else { return }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    guard configuration.verifier.accepts(peerOf: descriptor) else {
      // Whoever it is, it is not this application's companion agent.
      close(descriptor)
      diagnostics.record(.lifecycle, .error, "companion.peerRefused")
      Self.logger.error("a peer that is not the companion agent was refused")
      return
    }
    connection?.close()
    let connection = CompanionLinkConnection(descriptor: descriptor)
    self.connection = connection
    connection.send(
      .hello(
        protocolVersion: CompanionLinkWire.protocolVersion,
        installationID: configuration.installationID, version: configuration.version,
        buildLabel: configuration.buildLabel))
    if let latest { connection.send(.snapshot(Self.wire(latest))) }
    diagnostics.record(.lifecycle, .notice, "companion.agentConnected")
    Self.logger.notice(
      "agent connected, hello sent, snapshot: \(self.latest != nil, privacy: .public)")
    Task { await self.read(connection) }
  }

  private func read(_ connection: CompanionLinkConnection) async {
    for await message in connection.messages {
      switch message {
      case .testReceived(let ping):
        Self.logger.notice(
          "test \(ping.nonce, privacy: .public) received from \(ping.deviceName, privacy: .public)")
        let test = CompanionTest(
          nonce: ping.nonce, deviceName: ping.deviceName, sentAt: ping.sentAt)
        // Not awaited: the next message is never held up by this one's alert.
        if let onTest { Task { await onTest(test) } }
      case .welcome:
        Self.logger.notice("agent says welcome")
      case .hello, .snapshot, .testAcknowledged:
        break
      }
    }
    guard self.connection === connection else { return }
    self.connection = nil
    diagnostics.record(.lifecycle, .notice, "companion.agentDisconnected")
    Self.logger.notice("agent disconnected")
    await launchAgent()
  }

  static func wire(_ snapshot: CompanionSnapshot) -> [CompanionSessionInfo] {
    snapshot.sessions.map { session in
      CompanionSessionInfo(
        id: session.id.rawValue.uuidString, title: session.title, agent: session.agent,
        state: CompanionSessionState(rawValue: session.state.rawValue) ?? .waiting)
    }
  }
}

/// The agent's command line, which the application writes and the agent reads.
public enum CompanionAgentArguments {
  public static let link = "--link"
  public static let state = "--state"
}
