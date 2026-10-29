import CompanionCore
import Foundation
import IrohLib
import Observation
import Security
import UIKit

/// The phone's end of the direct channel (#399, #400): the Mac's sessions, the conversation shown,
/// and what the user does to them, over iroh while the application is in the foreground.
///
/// The phone's endpoint keeps one key, in the Keychain: its identifier is what the user's private
/// database lists as paired (`CompanionDevice`), and the Mac admits that identifier alone.
@Observable
@MainActor
final class RemoteChannel {
  enum Phase: Equatable {
    case idle
    /// The Mac has not published an endpoint: Vibe Manager closed, or the Mac asleep.
    case noMac
    case connecting
    case connected
    case failed(String)
  }

  private(set) var phase = Phase.idle
  private(set) var macName: String?
  /// The protocol the Mac said it speaks, at its welcome.
  private(set) var macProtocolVersion: Int?
  private(set) var sessions: [RemoteSession] = []
  private(set) var conversation: RemoteConversation?
  private(set) var searchResults: [RemoteSearchResult] = []
  /// What a new session can be, once the Mac said.
  private(set) var newSessionOptions: RemoteNewSessionOptions?
  /// The folders listed for the browser, by path.
  private(set) var folderListings: [String: RemoteFolderListing] = [:]
  /// The home folder's path, once listed.
  private(set) var homePath: String?
  /// The web view shown, and the latest picture of its page.
  private(set) var webState: RemoteWebState?
  /// Bumped to reload the phone's web view along with the Mac's.
  var reloadWeb = 0
  /// The requests of the phone's web view the Mac is making, by identifier.
  @ObservationIgnored private var fetches: [Int: CheckedContinuation<RemoteHTTPResponse, Never>] =
    [:]
  @ObservationIgnored private var nextFetch = 0
  private var webSessionID: String?
  /// The project icons of folders, by path: `.some(nil)` for a folder without one.
  private(set) var folderIcons: [String: UIImage?] = [:]
  /// The pictures of the images joined to messages, by their path on the Mac.
  private(set) var attachmentImages: [String: UIImage] = [:]
  @ObservationIgnored private var askedAttachments: Set<String> = []
  /// The project icons the sessions wear, by content: asked once, kept in the caches.
  private(set) var icons: [String: UIImage] = [:]
  @ObservationIgnored private var askedIcons: Set<String> = []
  /// The session just created from the phone, for the list to show it.
  var createdSessionID: String?
  /// The session a tapped notification is about (#401): the list opens it.
  var notifiedSessionID: String?
  /// The last thing the Mac could not do, for an alert.
  var failure: RemoteFailure?
  /// This phone's endpoint, once bound: what pairing writes.
  private(set) var endpointID: String?
  private(set) var path = CompanionPathKind.unknown

  private var endpoint: Endpoint?
  private var connection: Connection?
  private var sending: RemoteFrameQueue?
  private var tasks: [Task<Void, Never>] = []
  private var attempt = 0
  private var shownSessionID: String?
  private var searchToken = 0
  private let deviceName: String
  /// Called with the endpoint's identifier as soon as it is bound, for the pairing record.
  var onEndpoint: ((String) async -> Void)?

  init(deviceName: String) {
    self.deviceName = deviceName
  }

  // MARK: - Connection

  func open(to mac: CompanionMac?) {
    close()
    guard let mac, let endpointID = mac.irohEndpointID else {
      phase = .noMac
      return
    }
    let attempt = self.attempt
    phase = .connecting
    tasks.append(
      Task { await connect(endpointID: endpointID, relay: mac.irohRelayURL, attempt: attempt) })
  }

  func close() {
    for (id, continuation) in fetches {
      continuation.resume(
        returning: RemoteHTTPResponse(
          id: id, status: 0, headers: [:], body: Data(),
          failure: String(localized: "Connection lost")))
    }
    fetches = [:]
    attempt += 1
    tasks.forEach { $0.cancel() }
    tasks = []
    let (endpoint, connection) = (endpoint, connection)
    self.endpoint = nil
    self.connection = nil
    sending?.finish()
    sending = nil
    Task.detached {
      try? connection?.close(errorCode: 0, reason: Data("background".utf8))
      try? await endpoint?.close()
    }
    if phase == .connecting || phase == .connected { phase = .idle }
    path = .unknown
    // The next Mac says its own in its welcome.
    macProtocolVersion = nil
  }

  private func connect(endpointID: String, relay: String?, attempt: Int) async {
    do {
      let endpoint = try await Endpoint.bind(
        options: CompanionIroh.options(secretKey: try Self.secretKey()))
      guard self.attempt == attempt else {
        try? await endpoint.close()
        return
      }
      self.endpoint = endpoint
      let own = endpoint.id().description
      self.endpointID = own
      await onEndpoint?(own)
      let address = EndpointAddr(
        id: try EndpointId.fromString(s: endpointID), relayUrl: relay, addresses: [])
      let connection = try await endpoint.connect(addr: address, alpn: CompanionIroh.remoteALPN)
      guard self.attempt == attempt else { return }
      self.connection = connection
      let stream = try await connection.openBi()
      guard self.attempt == attempt else { return }
      let send = stream.send()
      sending = RemoteFrameQueue { try await send.writeAll(buf: $0) }
      phase = .connected
      path = CompanionIroh.pathKind(connection.paths())
      CompanionIroh.logger.notice(
        "remote: connected, \(CompanionIroh.describe(connection.paths()), privacy: .public)")
      write(.hello(protocolVersion: CompanionRemote.protocolVersion, deviceName: deviceName))
      if let shownSessionID { write(.show(sessionID: shownSessionID)) }
      if let webSessionID { write(.showWeb(sessionID: webSessionID)) }
      // Icons asked while the channel was down are asked again.
      for id in askedIcons where icons[id] == nil { write(.icon(id: id)) }
      for path in askedAttachments where attachmentImages[path] == nil {
        write(.attachmentImage(path: path))
      }
      tasks.append(
        Task.detached { [weak self] in await self?.receive(on: stream, attempt: attempt) })
      tasks.append(
        Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.attempt == attempt else { return }
            self.path = CompanionIroh.pathKind(connection.paths())
          }
        })
    } catch {
      fail(CompanionIroh.describe(error), attempt: attempt)
    }
  }

  private nonisolated func receive(on stream: BiStream, attempt: Int) async {
    let receiving = stream.recv()
    var decoder = RemoteFrame.Decoder()
    do {
      while !Task.isCancelled {
        let header = try await receiving.readExact(size: 4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= RemoteFrame.maximumLength else { throw RemoteFrame.Failure.tooLong(length) }
        let body = length == 0 ? Data() : try await receiving.readExact(size: UInt32(length))
        let messages = try decoder.append(header + body)
        await MainActor.run {
          for message in messages { self.apply(message, attempt: attempt) }
        }
      }
    } catch {
      await fail(CompanionIroh.describe(error), attempt: attempt)
    }
  }

  private func apply(_ message: RemoteMessage, attempt: Int) {
    guard self.attempt == attempt else { return }
    switch message {
    case .welcome(let version, let macName):
      self.macName = macName
      macProtocolVersion = version
    case .sessions(let sessions):
      self.sessions = sessions
    case .conversation(let conversation):
      guard conversation.sessionID == shownSessionID else { return }
      self.conversation = conversation
    case .searchResults(let token, let results):
      guard token == searchToken else { return }
      searchResults = results
    case .newSessionOffer(let options):
      newSessionOptions = options
    case .webState(let state):
      guard state.sessionID == webSessionID else { return }
      webState = state
    case .httpResponse(let response):
      fetches.removeValue(forKey: response.id)?.resume(returning: response)
    case .folderIconData(let path, let png):
      folderIcons[path] = png.flatMap(UIImage.init(data:)).map(Optional.some) ?? .some(nil)
    case .attachmentData(let path, let jpeg):
      attachmentImages[path] = UIImage(data: jpeg)
    case .iconData(let id, let png):
      guard let image = UIImage(data: png) else { return }
      icons[id] = image
      try? FileManager.default.createDirectory(
        at: Self.iconFolder, withIntermediateDirectories: true)
      try? png.write(to: Self.iconFolder.appendingPathComponent("\(id).png"))
    case .folderListing(let listing):
      folderListings[listing.path] = listing
      if pendingHome {
        pendingHome = false
        homePath = listing.path
      }
    case .created(let id):
      createdSessionID = id
    case .failure(let reason):
      failure = reason
    case .hello, .show, .send, .sendFiles, .answer, .answers, .setStatus, .search, .newSessionOptions,
      .createSession, .listFolder, .icon, .interrupt, .showWeb, .web, .attachmentImage, .restart,
      .httpRequest, .folderIcon, .close:
      break
    }
  }

  private func fail(_ reason: String, attempt: Int) {
    guard self.attempt == attempt else { return }
    CompanionIroh.logger.error("remote: failed: \(reason, privacy: .public)")
    close()
    phase = .failed(reason)
  }

  private func write(_ message: RemoteMessage) {
    guard let sending else { return }
    sending.enqueue(RemoteFrame.encode(message))
  }

  // MARK: - What the user does

  func show(_ sessionID: String?) {
    shownSessionID = sessionID
    if conversation?.sessionID != sessionID { conversation = nil }
    write(.show(sessionID: sessionID))
  }

  func send(_ text: String, files: [RemoteFile] = [], to sessionID: String) {
    write(
      files.isEmpty
        ? .send(sessionID: sessionID, text: text)
        : .sendFiles(sessionID: sessionID, text: text, files: files))
  }

  func answer(_ request: RemoteRequest, in sessionID: String, choiceIDs: [String], text: String?) {
    write(.answer(sessionID: sessionID, requestID: request.id, choiceIDs: choiceIDs, text: text))
  }

  /// One answer per question (#428); to a Mac of protocol 1, which shows a single question, the
  /// first only.
  func answer(_ request: RemoteRequest, in sessionID: String, answers: [RemoteAnswer]) {
    if CompanionRemote.takesAnswers(macProtocolVersion) {
      write(.answers(sessionID: sessionID, requestID: request.id, answers: answers))
    } else if let first = answers.first {
      answer(request, in: sessionID, choiceIDs: first.choiceIDs, text: first.text)
    }
  }

  func setStatus(_ status: RemoteTaskStatus, of sessionID: String) {
    // Moved at once on the phone; the Mac's list follows.
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
      sessions[index].status = status
    }
    write(.setStatus(sessionID: sessionID, status: status))
  }

  func search(_ query: String) {
    searchToken += 1
    write(.search(query: query, token: searchToken))
  }

  func askNewSessionOptions() {
    write(.newSessionOptions)
  }

  private var pendingHome = false

  /// A project icon: from memory, the caches, or asked of the Mac once.
  func icon(_ id: String) -> UIImage? {
    if let image = icons[id] { return image }
    guard !askedIcons.contains(id) else { return nil }
    askedIcons.insert(id)
    let file = Self.iconFolder.appendingPathComponent("\(id).png")
    if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
      // Set after the view that asked has drawn: never during its body.
      Task { @MainActor in self.icons[id] = image }
      return nil
    }
    Task { @MainActor in self.write(.icon(id: id)) }
    return nil
  }

  private static var iconFolder: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ProjectIcons", isDirectory: true)
  }

  /// Shows a session's web view, mirrored; `nil` when the phone leaves it.
  func showWeb(_ sessionID: String?) {
    webSessionID = sessionID
    if webState?.sessionID != sessionID { webState = nil }
    write(.showWeb(sessionID: sessionID))
  }

  func web(_ action: RemoteWebAction, in sessionID: String) {
    write(.web(sessionID: sessionID, action))
  }

  /// A request of the web view for a page of the Mac's own, made by the Mac.
  func fetch(url: URL, method: String, headers: [String: String], body: Data?) async
    -> RemoteHTTPResponse
  {
    nextFetch += 1
    let id = nextFetch
    guard sending != nil else {
      return RemoteHTTPResponse(
        id: id, status: 0, headers: [:], body: Data(),
        failure: String(localized: "Not connected to the Mac"))
    }
    return await withCheckedContinuation { continuation in
      fetches[id] = continuation
      write(
        .httpRequest(
          RemoteHTTPRequest(
            id: id, url: url.absoluteString, method: method, headers: headers, body: body)))
    }
  }

  /// The picture of an image joined to a message: asked of the Mac once.
  func attachmentImage(_ path: String) -> UIImage? {
    if let image = attachmentImages[path] { return image }
    if askedAttachments.insert(path).inserted {
      Task { @MainActor in self.write(.attachmentImage(path: path)) }
    }
    return nil
  }

  /// Asks for a folder's project icon, once.
  func askFolderIcon(_ path: String) {
    guard folderIcons[path] == nil else { return }
    write(.folderIcon(path: path))
  }

  func close(_ sessionID: String) {
    write(.close(sessionID: sessionID))
  }

  func restart(_ sessionID: String) {
    write(.restart(sessionID: sessionID))
  }

  /// Stops what the agent does.
  func interrupt(_ sessionID: String) {
    write(.interrupt(sessionID: sessionID))
  }

  /// Asks for a folder's subfolders; `nil` for the home folder.
  func list(_ path: String?) {
    if path == nil { pendingHome = true }
    write(.listFolder(path: path))
  }

  func create(_ session: RemoteNewSession) {
    write(.createSession(session))
  }

  // MARK: - Key

  private static let keyService = "eu.hadrien.VibeManager.Companion.iroh"

  /// The endpoint's key, made once and kept in the Keychain, on this device only.
  private static func secretKey() throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keyService,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, data.count == 32
    {
      return data
    }
    let key = SecretKey.generate().toBytes()
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keyService,
      // No user presence asked: the channel opens by itself at each return to the foreground, and
      // the key never leaves this device. As the Mac keeps its endpoints' secrets.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: key,
    ]
    SecItemDelete(
      [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keyService]
        as CFDictionary)
    SecItemAdd(add as CFDictionary, nil)
    return key
  }
}
