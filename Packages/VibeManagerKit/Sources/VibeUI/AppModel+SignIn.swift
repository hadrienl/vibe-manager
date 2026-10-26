import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain

/// Where a sign-in started from a conversation stands (#410).
public enum AgentSignInProgress: Equatable, Sendable {
  case running
  /// What the CLI said, and when: a session stopped on its sign-in after that is a new expiry.
  case failed(detail: String?, at: Date)
}

/// The CLI's sign-in expired (#410): signed in again from the conversation, in the browser, once
/// for every session of that agent — and each session it had stopped is restarted, its
/// conversation resumed, and handed back the prompt that failed.
extension AppModel {
  func loadSigningInAgents() async {
    guard let agents else { return }
    var signing: Set<AgentProviderID> = []
    for descriptor in await agents.descriptors()
    where await agents.provider(id: descriptor.id) is any AgentSigningIn {
      signing.insert(descriptor.id)
    }
    signingInAgents = signing
    publishSignIns()
  }

  // MARK: - Commands

  /// Signs the session's agent in again. One sign-in at a time per agent: every session waiting
  /// on it shows the same one.
  public func signIn(from id: SessionID) {
    guard let provider = agentProvider(of: id), signingInAgents.contains(provider),
      signInTasks[provider] == nil, signInRoutes[provider]?.route == .browser,
      let agents
    else { return }
    signIns[provider] = .running
    publishSignIns()
    signInTasks[provider] = Task { [weak self] in
      let outcome =
        await (agents.provider(id: provider) as? any AgentSigningIn)?.signIn()
        ?? .notSignedIn(detail: nil)
      await self?.signInEnded(provider, outcome: outcome)
    }
  }

  public func cancelSignIn(from id: SessionID) {
    guard let provider = agentProvider(of: id) else { return }
    signInTasks[provider]?.cancel()
  }

  /// Resumes a session the sign-in did not: text was waiting in its prompt, or it was busy. The
  /// text the notice showed is sent in place of the prompt that failed.
  public func resumeAfterSignIn(_ id: SessionID) {
    guard resumingAfterSignIn.insert(id).inserted else { return }
    let shown: String? =
      if case .text(let text)? = signInWaiting.removeValue(forKey: id) { text } else { nil }
    publishSignIn(for: id)
    Task { await resumeSignedIn(id, sending: shown) }
  }

  /// The CLI's own sign-in, in the session's terminal: for when the one run from here failed.
  public func signInInTerminal(_ id: SessionID) {
    guard let launcher else { return }
    setPresentation(.terminal, of: id)
    Task {
      _ = await launcher.typeMessage("/login", into: id) { .atRest }
    }
  }

  func signInEnded(_ provider: AgentProviderID, outcome: AgentSignInOutcome) async {
    signInTasks[provider] = nil
    switch outcome {
    case .signedIn:
      signIns[provider] = nil
      signedInAt[provider] = Date()
    case .cancelled:
      signIns[provider] = nil
    case .notSignedIn(let detail):
      signIns[provider] = .failed(detail: detail, at: Date())
    }
    guard outcome == .signedIn else {
      publishSignIns()
      return
    }
    // Every session it stopped says it resumes from now on, not that text waits in it: each is
    // looked at in its turn.
    let blocked = sessions.map(\.id).filter {
      agentProvider(of: $0) == provider && signInRequest(of: $0) != nil
        && canRestartInPlace($0)
    }
    resumingAfterSignIn.formUnion(blocked)
    publishSignIns()
    // One at a time, as the restarts onto an update are: each reloads the list.
    for id in blocked {
      await resumeSignedIn(id)
    }
    // The settings say so too.
    await refreshAgents(forceRefresh: false)
  }

  // MARK: - Resuming

  /// Restarts the session, its conversation resumed — a process started before the sign-in may
  /// not read the account again —, and types the prompt that failed back into it. The session is
  /// marked as resuming by the caller.
  ///
  /// Only when nothing would be lost, as for an update (#409): no other command at work on it,
  /// nothing running behind it — a sign-in that failed stops the turn, not a shell or an agent in
  /// the background. Asked again after every wait. Text typed into its prompt is the user's to
  /// send: only once the notice has shown it, `waitingText`, and it is still what the prompt
  /// holds — typed back in place of the prompt that failed.
  func resumeSignedIn(_ id: SessionID, sending waitingText: String? = nil) async {
    defer {
      resumingAfterSignIn.remove(id)
      publishSignIn(for: id)
    }
    guard let launcher, let session = sessions.first(where: { $0.id == id }),
      isStillStoppedOnSignIn(id)
    else { return }
    let entries = await conversations.entries(of: session)
    // A sign-in that expired once the agent was at work leaves no prompt to hand back: it is
    // told to go on from where it stopped (#419).
    var prompt =
      entries.flatMap(ConversationEntry.promptFailedOnSignIn(in:))
      ?? (entries.map(ConversationEntry.turnFailedOnSignInMidway(in:)) == true
        ? Self.continuePrompt : nil)
    guard let screen = await launcher.screen(of: id) else { return }
    let runsInBackground = await runsBackgroundWork(id)
    guard isStillStoppedOnSignIn(id) else { return }
    guard !runsInBackground, !AgentUpdateRestartReadiness.runsInBackground(screen: screen) else {
      signInWaiting[id] = .work
      return
    }
    if !AgentUpdateRestartReadiness.promptIsEmpty(screen: screen) {
      let typed = PromptInputRecognition.input(screen: screen).flatMap(
        PromptInputRecognition.text(of:))
      guard let typed, typed == waitingText else {
        signInWaiting[id] = .text(typed)
        return
      }
      prompt = typed
    }
    guard await restartInPlace(id), let prompt else { return }
    await typeBack(prompt, into: id)
  }

  /// What a turn the sign-in stopped half way is resumed with (#419).
  static let continuePrompt = "continue"

  /// The session still waits on its sign-in, and nothing else is at work on it.
  private func isStillStoppedOnSignIn(_ id: SessionID) -> Bool {
    let runsSubagents =
      conversations.existingModel(for: id)?.trayItems.contains { !$0.hasEnded } ?? false
    return signInRequest(of: id) != nil && isFreeForUpdateRestart(id) && !runsSubagents
  }

  /// How long a restarted agent is waited for before its prompt is given up on.
  static let signInResumeAttempts = 90

  /// Types the prompt once the restarted agent is ready for it, as a coordinator's message is.
  private func typeBack(_ prompt: String, into id: SessionID) async {
    for _ in 0..<Self.signInResumeAttempts {
      try? await Task.sleep(for: .seconds(1))
      guard let launcher, launcher.isRunning(id) else { return }
      guard ConversationWorkspace.isReady(activity(for: id)),
        let screen = await launcher.screen(of: id),
        AgentUpdateRestartReadiness.promptIsEmpty(screen: screen)
      else { continue }
      if await typeCoordinationMessage(prompt, into: id) { return }
    }
  }

  // MARK: - Conversation

  /// The request a session's agent stopped on because its sign-in expired, first in its queue.
  func signInRequest(of id: SessionID) -> AgentRequest? {
    guard let request = activity(for: id)?.requests.first,
      case .inTerminal(let prompt) = request.content, prompt.asksToSignIn
    else { return nil }
    return request
  }

  func publishSignIns() {
    for session in sessions { publishSignIn(for: session.id) }
  }

  func publishSignIn(for id: SessionID) {
    if let request = signInRequest(of: id), let provider = agentProvider(of: id) {
      lookUpSignInRoute(of: provider, after: request.receivedAt)
    }
    guard let model = conversations.existingModel(for: id) else { return }
    let notice = signInNotice(for: id)
    if model.signIn != notice { model.signIn = notice }
  }

  /// Asks the CLI how its account is signed in again, once per expiry: the account may have
  /// changed since the last one.
  func lookUpSignInRoute(of provider: AgentProviderID, after expiry: Date) {
    guard (signInRoutes[provider]?.at ?? .distantPast) < expiry,
      signInRouteLookups.insert(provider).inserted, let agents
    else { return }
    Task { [weak self] in
      let route =
        await (agents.provider(id: provider) as? any AgentSigningIn)?.signInRoute() ?? .browser
      guard let self else { return }
      self.signInRouteLookups.remove(provider)
      self.signInRoutes[provider] = (route, Date())
      self.publishSignIns()
    }
  }

  func signInNotice(for id: SessionID) -> ConversationSignIn? {
    guard let provider = agentProvider(of: id), signingInAgents.contains(provider) else {
      return nil
    }
    let name =
      agentDescriptors.first { $0.id == provider }?.displayName
      ?? agentDiagnostics.first { $0.providerID == provider }?.providerName ?? ""
    let first = activity(for: id)?.requests.first
    if resumingAfterSignIn.contains(id) {
      // Another request — a dialog of the restarted CLI's start — is the user's to see.
      guard first == nil || signInRequest(of: id) != nil else { return nil }
      return ConversationSignIn(agentName: name, state: .resuming)
    }
    guard let request = signInRequest(of: id) else { return nil }
    let route: ConversationSignIn.Route =
      switch signInRoutes[provider]?.route {
      case .terminal?: .terminal
      case .elsewhere?: .elsewhere
      case .browser?: .browser
      case nil: .unknown
      }
    switch signIns[provider] {
    case .running?:
      return ConversationSignIn(agentName: name, state: .signingIn, route: route)
    case .failed(let detail, let at)? where at > request.receivedAt:
      return ConversationSignIn(agentName: name, state: .failed(detail: detail), route: route)
    case .failed?, nil:
      if let signedIn = signedInAt[provider], signedIn > request.receivedAt {
        return ConversationSignIn(
          agentName: name,
          state: .signedIn(
            canResume: canRestartInPlace(id), waiting: signInWaiting[id]),
          route: route)
      }
      return ConversationSignIn(agentName: name, state: .expired, route: route)
    }
  }
}
