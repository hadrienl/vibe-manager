import CompanionCore
import Foundation
import Observation
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeUI
import os

/// The application's end of the direct channel (#399, #400): what a paired phone sees and does,
/// read from and done through the same model as the window. The companion agent only relays.
///
/// Each phone gets every session at once and at each change, and the conversation it shows, whole,
/// at each change of it. What it asks is done as the window's own controls do it: a message goes
/// through the conversation's composer, an answer through `AppModel.answer`, a status through
/// `AppModel.setTaskStatus`.
@MainActor
final class CompanionRemoteServer {
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "remote")
  /// A conversation's last entries: a long session's whole history would weigh megabytes, and the
  /// phone shows the end.
  private static let entryLimit = 300

  private struct Peer {
    var shown: SessionID?
    var conversationRevision = 0
  }

  private weak var appModel: AppModel?
  private let send: @MainActor (String, RemoteMessage) -> Void
  private let macName: String
  private var peers: [String: Peer] = [:]
  private var sessionsObserved = false
  private var lastSessions: [RemoteSession] = []
  private var searchIndex: SessionSearchIndex?

  init(
    appModel: AppModel, macName: String, send: @escaping @MainActor (String, RemoteMessage) -> Void
  ) {
    self.appModel = appModel
    self.macName = macName
    self.send = send
  }

  func receive(_ message: RemoteMessage, from peer: String) {
    switch message {
    case .hello(_, let deviceName):
      Self.logger.notice(
        "\(peer, privacy: .public): hello from \(deviceName, privacy: .public)")
      peers[peer] = Peer()
      send(peer, .welcome(protocolVersion: CompanionRemote.protocolVersion, macName: macName))
      observeSessions()
      send(peer, .sessions(lastSessions))
    case .show(let id):
      guard peers[peer] != nil else { return }
      let sessionID = id.flatMap(UUID.init(uuidString:)).map(SessionID.init(rawValue:))
      peers[peer]?.shown = sessionID
      peers[peer]?.conversationRevision += 1
      if let sessionID { follow(sessionID, for: peer) }
    case .send(let id, let text):
      Task { await self.type(text, into: id, for: peer) }
    case .answer(let id, let requestID, let choiceIDs, let text):
      Task { await self.answer(id, requestID: requestID, choiceIDs: choiceIDs, text: text, for: peer) }
    case .setStatus(let id, let status):
      guard let appModel, let sessionID = Self.sessionID(id),
        let taskStatus = SessionTaskStatus(rawValue: status.rawValue)
      else { return }
      Task { await appModel.setTaskStatus(taskStatus, for: sessionID) }
    case .search(let query, let token):
      Task { await self.search(query, token: token, for: peer) }
    case .newSessionOptions:
      Task { await self.offerNewSession(to: peer) }
    case .createSession(let request):
      Task { await self.create(request, for: peer) }
    case .listFolder(let path):
      let listing = Self.listing(of: path)
      send(peer, .folderListing(listing))
    case .welcome, .sessions, .conversation, .searchResults, .failure, .newSessionOffer, .created,
      .folderListing:
      break
    }
  }

  func closed(_ peer: String) {
    peers[peer] = nil
    Self.logger.notice("\(peer, privacy: .public): gone")
  }

  // MARK: - Sessions

  /// Reads the sessions under observation and sends them to every phone at each change.
  private func observeSessions() {
    guard !sessionsObserved || lastSessions.isEmpty else { return }
    sessionsObserved = true
    readSessions()
  }

  private func readSessions() {
    guard let appModel else { return }
    let sessions = withObservationTracking {
      Self.remoteSessions(of: appModel)
    } onChange: { [weak self] in
      Task { @MainActor in self?.readSessions() }
    }
    guard sessions != lastSessions else { return }
    lastSessions = sessions
    for peer in peers.keys { send(peer, .sessions(sessions)) }
  }

  static func remoteSessions(of appModel: AppModel) -> [RemoteSession] {
    let names = Dictionary(
      appModel.agentDescriptors.map { ($0.id.rawValue, $0.displayName) },
      uniquingKeysWith: { first, _ in first })
    return appModel.sessions.map { session in
      let path = SessionFolderKey.primaryPath(of: session) ?? ""
      let label =
        appModel.folderLabels[SessionFolderKey(path: path)]
        ?? (path.isEmpty ? "" : (path as NSString).lastPathComponent)
      let state = appModel.activity(for: session.id)
      let providerID = session.agent?.providerID ?? ""
      var coordinatorID: String?
      var isCoordinator = false
      switch session.coordination {
      case .coordinator: isCoordinator = true
      case .child(let id): coordinatorID = id.rawValue.uuidString
      case nil: break
      }
      return RemoteSession(
        id: session.id.rawValue.uuidString, name: session.name, folderPath: path,
        folderName: label, agentName: names[providerID] ?? providerID,
        status: RemoteTaskStatus(rawValue: session.taskStatus.rawValue) ?? .doing,
        activity: activity(of: session, state: state),
        appearance: RemoteAppearance(
          symbol: session.appearance.symbolName, color: session.appearance.colorHex),
        coordinatorID: coordinatorID, isCoordinator: isCoordinator,
        detail: state?.requests.first.map(detail(of:)), updatedAt: session.updatedAt,
        rank: session.rank)
    }
  }

  private static func activity(of session: WorkSession, state: AgentActivityState?)
    -> RemoteActivity
  {
    guard session.status == .active else { return .stopped }
    switch state?.activity {
    case .working: return .working
    case .awaitingUser: return .needsAttention
    case .idle, nil: return .idle
    }
  }

  /// The request on one line, as the sidebar's row says it.
  private static func detail(of request: AgentRequest) -> String {
    switch request.content {
    case .permission(let permission):
      return "Permission : \(permission.subject ?? permission.toolName)"
    case .questions(let questions):
      return "Question : \(questions.first?.text ?? "")"
    case .plan:
      return "Plan à valider"
    default:
      return "Attend ta réponse"
    }
  }

  // MARK: - Conversation

  /// Sends the conversation now and at each change, while the phone shows it.
  private func follow(_ id: SessionID, for peer: String) {
    guard let appModel, let session = appModel.sessions.first(where: { $0.id == id }) else {
      send(peer, .failure("Cette session n’existe plus sur le Mac."))
      return
    }
    let model = appModel.conversations.show(session)
    let revision = peers[peer]?.conversationRevision ?? 0
    sendConversation(of: id, model: model, revision: revision, to: peer)
  }

  private func sendConversation(
    of id: SessionID, model: ConversationModel, revision: Int, to peer: String
  ) {
    guard let appModel, peers[peer]?.shown == id,
      peers[peer]?.conversationRevision == revision
    else { return }
    let conversation = withObservationTracking {
      RemoteConversation(
        sessionID: id.rawValue.uuidString,
        entries: Self.entries(model.snapshot.entries.suffix(Self.entryLimit)),
        request: appModel.activity(for: id)?.requests.first.flatMap(Self.request(of:)))
    } onChange: { [weak self] in
      Task { @MainActor in
        // Coalesced: a generating agent changes the snapshot many times a second.
        try? await Task.sleep(for: .milliseconds(250))
        self?.sendConversation(of: id, model: model, revision: revision, to: peer)
      }
    }
    send(peer, .conversation(conversation))
  }

  static func entries(_ entries: some Sequence<ConversationEntry>) -> [RemoteEntry] {
    entries.compactMap { entry in
      let kind: RemoteEntry.Kind
      switch entry.content {
      case .userPrompt(let text, _):
        kind = .user(text)
      case .agentText(let text):
        kind = .agent(text)
      case .tool(let call):
        let title = ToolCallSummary.title(for: call)
        let running: Bool
        let failed: Bool
        switch call.state {
        case .running, .awaitingPermission: (running, failed) = (true, false)
        case .failed, .refused: (running, failed) = (false, true)
        default: (running, failed) = (false, false)
        }
        kind = .tool(
          symbol: title.symbolName, title: title.title, detail: title.outcome ?? title.detail,
          running: running, failed: failed)
      case .notice(let notice):
        switch notice {
        case .error(let text): kind = .notice(text)
        case .interrupted: kind = .notice("Interrompu")
        case .compacted: kind = .notice("Conversation résumée")
        case .shell(let run): kind = .notice("$ \(run.command)")
        default: return nil
        }
      case .reasoning:
        return nil
      }
      return RemoteEntry(id: entry.id, kind: kind, date: entry.date)
    }
  }

  static func request(of request: AgentRequest) -> RemoteRequest? {
    let id = request.id.key
    switch request.content {
    case .permission(let permission):
      var choices = [RemoteChoice(id: "allowOnce", label: "Autoriser")]
      if permission.alwaysAllow != nil {
        choices.append(RemoteChoice(id: "allowAlways", label: "Toujours autoriser"))
      }
      choices.append(RemoteChoice(id: "deny", label: "Refuser", isDestructive: true))
      return RemoteRequest(
        id: id, kind: .permission, title: permission.purpose ?? "Autoriser \(permission.toolName) ?",
        subject: permission.subject, choices: choices)
    case .questions(let questions):
      guard let question = questions.first else { return nil }
      return RemoteRequest(
        id: id, kind: .question, title: question.text, subject: question.header,
        choices: question.options.enumerated().map { index, option in
          RemoteChoice(id: String(index), label: option.label, detail: option.description)
        },
        allowsSeveral: question.allowsMultipleChoices, allowsText: question.allowsFreeText)
    default:
      return nil
    }
  }

  // MARK: - Actions

  /// Through the conversation's composer, as if typed in the window: a working agent gets it
  /// queued, an answer to a question goes as one. What the user left in the composer stays.
  private func type(_ text: String, into id: String, for peer: String) async {
    guard let appModel, let sessionID = Self.sessionID(id),
      let session = appModel.sessions.first(where: { $0.id == sessionID })
    else { return }
    let model = appModel.conversations.show(session)
    let kept = model.draft
    model.draft = text
    let sent = await model.send()
    if model.draft == text || sent { model.draft = kept }
    if !sent { send(peer, .failure("Le message n’a pas pu être envoyé : l’agent ne tourne pas.")) }
  }

  private func answer(
    _ id: String, requestID: String, choiceIDs: [String], text: String?, for peer: String
  ) async {
    guard let appModel, let sessionID = Self.sessionID(id),
      let request = appModel.activity(for: sessionID)?.requests.first(where: {
        $0.id.key == requestID
      })
    else {
      send(peer, .failure("Cette demande n’attend plus de réponse."))
      return
    }
    let answer: AgentAnswer
    switch request.content {
    case .permission:
      switch choiceIDs.first {
      case "allowAlways": answer = .allowAlways
      case "deny": answer = .deny
      default: answer = .allowOnce
      }
    case .questions(let questions):
      let indices = choiceIDs.compactMap(Int.init)
      if let text, !text.isEmpty {
        answer = .answers([.text(text)])
      } else if questions.first?.allowsMultipleChoices == true {
        answer = .answers([.options(Set(indices))])
      } else if let index = indices.first {
        answer = .answers([.option(index)])
      } else {
        return
      }
    default:
      return
    }
    if !(await appModel.answer(answer, to: request.id)) {
      send(peer, .failure("La réponse n’a pas pu être donnée : réponds sur le Mac."))
    }
  }

  private func search(_ query: String, token: Int, for peer: String) async {
    guard let appModel else { return }
    let index: SessionSearchIndex
    if let searchIndex {
      index = searchIndex
    } else {
      index = SessionSearchIndex()
      searchIndex = index
    }
    await index.update(sessions: appModel.sessions)
    let answer = await index.search(query)
    send(
      peer,
      .searchResults(
        token: token,
        answer.results.map {
          RemoteSearchResult(
            sessionID: $0.sessionID.rawValue.uuidString,
            reason: QuickOpenPresentation.reason($0.reason), isArchived: $0.isArchived)
        }))
  }

  private func offerNewSession(to peer: String) async {
    guard let appModel else { return }
    var agents: [RemoteAgent] = []
    for descriptor in appModel.agentDescriptors {
      let models = await appModel.companionModels(of: descriptor.id.rawValue)
      agents.append(
        RemoteAgent(
          id: descriptor.id.rawValue, name: descriptor.displayName,
          models: models.map {
            RemoteModel(id: $0.id, name: $0.displayName, isDefault: $0.isDefault)
          }))
    }
    send(
      peer,
      .newSessionOffer(
        RemoteNewSessionOptions(folders: appModel.companionRecentFolders, agents: agents)))
  }

  private func create(_ request: RemoteNewSession, for peer: String) async {
    guard let appModel else { return }
    do {
      let id = try await appModel.createCompanionSession(
        name: request.name, folder: request.folder, providerID: request.agentID,
        modelID: request.modelID, prompt: request.prompt, start: request.start,
        coordinates: request.coordinates)
      send(peer, .created(sessionID: id.rawValue.uuidString))
    } catch {
      send(peer, .failure(error.localizedDescription))
    }
  }

  /// The subfolders of a folder of the Mac, hidden ones and packages left out, as the Finder
  /// shows them.
  static func listing(of path: String?) -> RemoteFolderListing {
    let folder = URL(
      fileURLWithPath: path.map { ($0 as NSString).expandingTildeInPath }
        ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true
    ).standardizedFileURL
    do {
      let entries = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
      let names = entries.filter {
        let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
      }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      return RemoteFolderListing(path: folder.path, folders: names)
    } catch {
      return RemoteFolderListing(
        path: folder.path, folders: [], problem: "Ce dossier ne peut pas être lu sur le Mac.")
    }
  }

  private static func sessionID(_ text: String) -> SessionID? {
    UUID(uuidString: text).map(SessionID.init(rawValue:))
  }
}
