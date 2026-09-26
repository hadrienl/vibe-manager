import Foundation
import VibeApplication
import VibeDomain

/// A system notification about a request (#40).
public struct RequestNotification: Equatable, Sendable {
  public let id: AgentRequestID
  public let title: String
  public let body: String
  /// Allow is offered only for a permission answerable from outside and shown in full; the
  /// system asks to unlock before it acts from the lock screen.
  public let offersAllow: Bool
  public let offersDeny: Bool
}

/// Posts the notifications and the Dock badge of pending requests.
@MainActor
public protocol RequestNotifying: AnyObject {
  func post(_ notification: RequestNotification)
  func remove(_ ids: [AgentRequestID])
  /// The number on the Dock icon; `nil` shows none.
  func setBadge(_ count: Int?)
  /// Whether the system lets the application notify; `nil` when it has not been asked yet.
  func isAuthorized() async -> Bool?
}

/// An answer given from outside the terminal, said for a moment.
public struct RequestOutcome: Equatable, Sendable {
  public let id: UUID
  public let sessionName: String
  public let answer: AgentAnswer
  public let outcome: AnswerAgentRequest.Outcome
}

extension AppModel {
  /// Every request waiting in a session other than the one in front of the user, oldest first
  /// (#40). The session on screen answers its own, in its terminal.
  public var pendingRequests: [PendingRequest] {
    allPendingRequests.filter { $0.session.id != selectedSessionID }
  }

  /// Every request waiting, the session on screen's included: the Dock counts them all, the user
  /// may be in another application.
  var allPendingRequests: [PendingRequest] {
    var result: [PendingRequest] = []
    for session in sessions where session.taskStatus != .archived {
      guard let requests = activities[session.id]?.requests, !requests.isEmpty else { continue }
      let folder = RestartSession.workingDirectoryPath(of: session)
      for (position, request) in requests.enumerated() {
        result.append(
          PendingRequest(
            request: request,
            session: session,
            answering: requestAnswering[request.id] ?? .inTerminalOnly(.notSupported),
            position: position,
            queueCount: requests.count,
            agentName: session.agent.map { agentNames[$0.providerID] ?? $0.providerID },
            folderName: folder.map { URL(fileURLWithPath: $0).lastPathComponent },
            folderPath: folder,
            branch: branch(of: session)
          ))
      }
    }
    return result.sorted {
      ($0.request.receivedAt, $0.position) < ($1.request.receivedAt, $1.position)
    }
  }

  /// The branch the session works on: as last read on disk, or as recorded when it started.
  private func branch(of session: WorkSession) -> String? {
    guard let repository = session.repositories.first else { return nil }
    let live = repositoryStatus(for: session.id, path: repository.path)?.lastValid?.branch
      .branchName
    return live ?? repository.git?.branchName
  }

  public var isRequestPaletteCollapsed: Bool {
    layout.intent.isRequestPaletteCollapsed
  }

  public func setRequestPaletteCollapsed(_ isCollapsed: Bool) {
    layout.setRequestPaletteCollapsed(isCollapsed)
  }

  // MARK: - Answering

  /// Types `answer` into the terminal of the request's session. The session on screen is neither
  /// changed nor sent anything.
  public func answer(_ answer: AgentAnswer, to id: AgentRequestID) async {
    guard let answerRequest, !answeringRequestIDs.contains(id) else { return }
    let name = sessions.first { $0.id == id.sessionID }?.name ?? ""
    answeringRequestIDs.insert(id)
    let outcome = await answerRequest(answer, to: id)
    answeringRequestIDs.remove(id)
    requestOutcome = RequestOutcome(
      id: UUID(), sessionName: name, answer: answer, outcome: outcome)
    Announcer.announce(Self.announcement(of: answer, outcome: outcome, sessionName: name))
  }

  /// Clears the word said about the last answer, once it has been read.
  public func dismissRequestOutcome(_ id: UUID) {
    guard requestOutcome?.id == id else { return }
    requestOutcome = nil
  }

  static func announcement(
    of answer: AgentAnswer, outcome: AnswerAgentRequest.Outcome, sessionName: String
  ) -> LocalizedStringResource {
    guard outcome == .sent else {
      return LocalizedStringResource(
        "The request of \(sessionName) was no longer waiting: nothing was sent.", bundle: .module,
        comment: "Said when an answer from the palette could not be typed into its session.")
    }
    switch answer {
    case .allowOnce, .allowAlways, .approvePlan:
      return LocalizedStringResource(
        "Allowed · \(sessionName)", bundle: .module,
        comment: "Said once an agent's request was allowed from the palette.")
    case .deny, .rejectPlan:
      return LocalizedStringResource(
        "Refused · \(sessionName)", bundle: .module,
        comment: "Said once an agent's request was refused from the palette.")
    case .answers:
      return LocalizedStringResource(
        "Answered · \(sessionName)", bundle: .module,
        comment: "Said once an agent's question was answered from the palette.")
    }
  }

  /// Opens the session a request comes from, in its column, with the keyboard in its terminal:
  /// the one gesture of the palette that changes the session on screen.
  public func openSession(for id: AgentRequestID) {
    guard let session = sessions.first(where: { $0.id == id.sessionID }) else { return }
    if session.taskStatus != .archived, filter.column != session.taskStatus {
      setColumn(session.taskStatus)
    }
    select(session.id)
    focusTerminal()
  }

  /// ⌥⌘P: unfolds the palette and gives it the keyboard.
  public func focusRequestPalette() {
    if !layout.columns.isSidebarVisible { layout.setSidebarVisible(true) }
    setRequestPaletteCollapsed(false)
    requestPaletteFocusRequest += 1
  }

  /// A notification was clicked: the application comes forward, the palette shows the request,
  /// and the session on screen stays.
  public func revealRequest(_ id: AgentRequestID) {
    revealedRequestID = id
    focusRequestPalette()
  }

  // MARK: - Signalling

  /// Called whenever the requests, the selection or the application's activity change: the Dock
  /// badge, VoiceOver and the notifications follow.
  func requestsDidChange() {
    let all = allPendingRequests
    let ids = Set(all.map(\.id))

    requestNotifier?.setBadge(showsRequestDockBadge && !all.isEmpty ? all.count : nil)

    let arrived = pendingRequests.filter { !announcedRequestIDs.contains($0.id) }
    announcedRequestIDs = announcedRequestIDs.intersection(ids).union(pendingRequests.map(\.id))
    if let first = arrived.first {
      Announcer.announce(
        LocalizedStringResource(
          "New request: \(first.session.name), \(RequestPresentation.title(of: first.request.content))",
          bundle: .module, comment: "Said when an agent in the background asks the user something.")
      )
      if expandsPaletteOnRequest { setRequestPaletteCollapsed(false) }
    }

    let gone = postedRequestIDs.subtracting(ids)
    if !gone.isEmpty {
      requestNotifier?.remove(Array(gone))
      postedRequestIDs.subtract(gone)
    }
    knownRequestIDs.formIntersection(ids)
    let unknown = all.filter { !knownRequestIDs.contains($0.id) }
    knownRequestIDs.formUnion(unknown.map(\.id))
    // Only what arrives while the application is in the background is notified: what arrived
    // while it was in front has been seen in the palette.
    guard !isApplicationActive, notifiesRequests, let notifier = requestNotifier else { return }
    for pending in unknown {
      notifier.post(notification(for: pending))
      postedRequestIDs.insert(pending.id)
    }
  }

  func notification(for pending: PendingRequest) -> RequestNotification {
    let title = [pending.session.name, pending.agentName].compactMap { $0 }.joined(
      separator: " — ")
    let answers = pending.answering.answers
    return RequestNotification(
      id: pending.id,
      title: DisplaySafeText.visible(title),
      body: RequestPresentation.notificationBody(
        of: pending.request.content, detail: requestNotificationContent),
      offersAllow: answers.contains(.allowOnce),
      offersDeny: answers.contains(.deny)
    )
  }
}
