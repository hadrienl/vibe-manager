import CompanionCore
import Foundation
import ImageIO
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
    /// The conversation it counts as a viewer of.
    var viewed: ConversationModel?
    /// The web view it shows, mirrored.
    var web: CompanionWebMirror?
    var conversationRevision = 0
  }

  private weak var appModel: AppModel?
  private let send: @MainActor (String, RemoteMessage) -> Void
  private let macName: String
  private let attachmentsFolder: URL
  private var peers: [String: Peer] = [:]
  private var sessionsObserved = false
  private var lastSessions: [RemoteSession] = []
  private var searchIndex: SessionSearchIndex?
  /// The files joined to the messages sent to phones: the only ones a phone may ask a picture of.
  private var servedAttachments: Set<String> = []

  init(
    appModel: AppModel, macName: String, attachmentsFolder: URL,
    send: @escaping @MainActor (String, RemoteMessage) -> Void
  ) {
    self.appModel = appModel
    self.macName = macName
    self.attachmentsFolder = attachmentsFolder
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
      release(peer)
      peers[peer]?.shown = sessionID
      peers[peer]?.conversationRevision += 1
      if let sessionID { follow(sessionID, for: peer) }
    case .send(let id, let text):
      Task { await self.type(text, into: id, for: peer) }
    case .sendFiles(let id, let text, let files):
      Task { await self.type(text, into: id, files: files, for: peer) }
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
    case .icon(let id):
      Task {
        guard let png = await appModel?.companionIconPNG(id).flatMap({ Self.thumbnail($0) })
        else { return }
        send(peer, .iconData(id: id, png: png))
      }
    case .folderIcon(let path):
      Task {
        let png = await appModel?.companionProjectIcon(inFolder: path).flatMap {
          Self.thumbnail($0)
        }
        send(peer, .folderIconData(path: path, png: png))
      }
    case .attachmentImage(let path):
      // Only a file a conversation sent to a phone joins: never any path a phone names.
      guard servedAttachments.contains(path) else { return }
      Task.detached {
        guard let data = FileManager.default.contents(atPath: path),
          let jpeg = Self.thumbnail(data, side: 800, type: "public.jpeg")
        else { return }
        await self.send(peer, .attachmentData(path: path, jpeg: jpeg))
      }
    case .close(let id):
      guard let appModel, let sessionID = Self.sessionID(id) else { return }
      Task { await appModel.close(sessionID) }
    case .restart(let id):
      guard let appModel, let sessionID = Self.sessionID(id) else { return }
      Task {
        await appModel.restart(sessionID)
        if appModel.pendingRestart?.sessionID == sessionID {
          send(
            peer,
            .failure(
              "Le Mac ne peut pas reprendre cette conversation et demande quoi faire : réponds sur le Mac."
            ))
        }
      }
    case .interrupt(let id):
      guard let sessionID = Self.sessionID(id) else { return }
      Self.logger.notice("\(peer, privacy: .public): interrupt \(id, privacy: .public)")
      Task { await appModel?.companionInterrupt(sessionID) }
    case .showWeb(let id):
      peers[peer]?.web?.stop()
      peers[peer]?.web = nil
      guard let appModel, let sessionID = id.flatMap(Self.sessionID) else { return }
      let mirror = CompanionWebMirror(
        sessionID: sessionID, appModel: appModel,
        send: { [weak self] message in self?.send(peer, message) })
      peers[peer]?.web = mirror
      mirror.start()
    case .web(let id, let action):
      guard let mirror = peers[peer]?.web, mirror.sessionID.rawValue.uuidString == id else { return }
      Task { await mirror.perform(action) }
    case .httpRequest(let request):
      Task {
        let response = await CompanionWebMirror.fetch(request)
        send(peer, .httpResponse(response))
      }
    case .listFolder(let path):
      let listing = Self.listing(of: path)
      send(peer, .folderListing(listing))
    case .welcome, .sessions, .conversation, .searchResults, .failure, .newSessionOffer, .created,
      .folderListing, .iconData, .webState, .attachmentData, .httpResponse, .folderIconData:
      break
    }
  }

  func closed(_ peer: String) {
    release(peer)
    peers[peer]?.web?.stop()
    peers[peer] = nil
    Self.logger.notice("\(peer, privacy: .public): gone")
  }

  /// The phone no longer shows its conversation: one viewer less.
  private func release(_ peer: String) {
    guard let model = peers[peer]?.viewed else { return }
    model.remoteViewers = max(0, model.remoteViewers - 1)
    peers[peer]?.viewed = nil
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
          symbol: session.appearance.symbolName, color: session.appearance.colorHex,
          iconID: session.appearance.iconID?.sha256),
        coordinatorID: coordinatorID, isCoordinator: isCoordinator,
        detail: state?.requests.first.map(detail(of:)), updatedAt: session.updatedAt,
        rank: session.rank, hasStarted: session.hasEverStarted)
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
    model.remoteViewers += 1
    peers[peer]?.viewed = model
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
    for entry in conversation.entries {
      if case .user(_, let attachments) = entry.kind {
        servedAttachments.formUnion(attachments.compactMap(\.path))
      }
    }
    send(peer, .conversation(conversation))
  }

  static func entries(_ entries: some Sequence<ConversationEntry>) -> [RemoteEntry] {
    entries.compactMap { entry in
      let kind: RemoteEntry.Kind
      switch entry.content {
      case .userPrompt(let text, let attachments):
        kind = .user(
          AttachedPaths.displayText(
            text, joinedCount: attachments.filter(\.isWrittenInText).count),
          attachments: attachments.enumerated().map { index, attachment in
            let url: URL? =
              switch attachment.source {
              case .file(let url), .fileWithEmbedded(let url, _): url
              default: nil
              }
            return RemoteAttachment(
              id: attachment.id,
              name: attachment.name ?? url?.lastPathComponent ?? "Image \(index + 1)",
              isImage: attachment.kind == .image, path: url?.path)
          })
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
  private func type(
    _ text: String, into id: String, files: [RemoteFile] = [], for peer: String
  ) async {
    guard let appModel, let sessionID = Self.sessionID(id),
      let session = appModel.sessions.first(where: { $0.id == sessionID })
    else { return }
    let model = appModel.conversations.show(session)
    let kept = model.draft
    // What the user left in the composer on the Mac is put aside, never sent with the phone's.
    let keptFiles = model.attachments
    keptFiles.forEach(model.removeAttachment)
    let written = saved(files)
    if !written.isEmpty { model.attach(written, focusing: false) }
    model.draft = text
    let sent = await model.send()
    model.attachments.filter(written.contains).forEach(model.removeAttachment)
    if !keptFiles.isEmpty { model.attach(keptFiles, focusing: false) }
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
    let palette = appModel.appearancePalette.offered
    send(
      peer,
      .newSessionOffer(
        RemoteNewSessionOptions(
          folders: appModel.companionRecentFolders, agents: agents, symbols: palette.symbols,
          colors: palette.swatches.map(\.hex),
          templates: appModel.companionTemplates.map { template in
            RemoteTemplate(
              id: template.id.rawValue.uuidString, name: template.name, body: template.body,
              folder: template.workingDirectoryPath.map { ($0 as NSString).expandingTildeInPath },
              appearance: template.appearance.map {
                RemoteAppearance(symbol: $0.symbolName, color: $0.colorHex)
              })
          })))
  }

  private func create(_ request: RemoteNewSession, for peer: String) async {
    guard let appModel else { return }
    do {
      let id = try await appModel.createCompanionSession(
        name: request.name, folder: request.folder, providerID: request.agentID,
        modelID: request.modelID, prompt: request.prompt, start: request.start,
        coordinates: request.coordinates,
        appearance: request.appearance.map {
          SessionAppearance(symbolName: $0.symbol, colorHex: $0.color)
        })
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

  /// The phone's files, written where the agent can read them: one folder per message, under the
  /// companion's own folder of the data folder.
  private func saved(_ files: [RemoteFile]) -> [URL] {
    guard !files.isEmpty else { return [] }
    let folder = attachmentsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      return []
    }
    return files.compactMap { file in
      // The name alone: never a path the phone could point elsewhere with.
      let name = (file.name as NSString).lastPathComponent
      let url = folder.appendingPathComponent(name.isEmpty ? "fichier" : name)
      return (try? file.data.write(to: url)) == nil ? nil : url
    }
  }

  /// A project icon at the size the phone draws it, 96 pixels: the stored one can be 1024.
  nonisolated static func thumbnail(
    _ png: Data, side: Int = 96, type: String = "public.png"
  ) -> Data? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary)
    else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, type as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  private static func sessionID(_ text: String) -> SessionID? {
    UUID(uuidString: text).map(SessionID.init(rawValue:))
  }
}
