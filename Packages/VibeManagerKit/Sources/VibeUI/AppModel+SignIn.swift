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
      signInTasks[provider] == nil, let agents
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

  /// Resumes a session the sign-in did not: text was waiting in its prompt, or it was busy.
  public func resumeAfterSignIn(_ id: SessionID) {
    guard resumingAfterSignIn.insert(id).inserted else { return }
    signInTextWaiting.remove(id)
    publishSignIn(for: id)
    Task { await resumeSignedIn(id) }
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
  /// nothing typed into its prompt, nothing running behind it — a sign-in that failed stops the
  /// turn, not a shell or an agent in the background. Asked again after every wait.
  func resumeSignedIn(_ id: SessionID) async {
    defer {
      resumingAfterSignIn.remove(id)
      publishSignIn(for: id)
    }
    guard let launcher, let session = sessions.first(where: { $0.id == id }),
      isStillStoppedOnSignIn(id)
    else { return }
    let prompt = await conversations.entries(of: session).flatMap(
      ConversationEntry.promptFailedOnSignIn(in:))
    guard let screen = await launcher.screen(of: id), isStillStoppedOnSignIn(id) else { return }
    guard AgentUpdateRestartReadiness.promptIsEmpty(screen: screen),
      !AgentUpdateRestartReadiness.runsInBackground(screen: screen)
    else {
      // Text the user typed, or work behind the prompt: theirs to resume when it is done.
      signInTextWaiting.insert(id)
      return
    }
    guard await restartInPlace(id), let prompt else { return }
    await typeBack(prompt, into: id)
  }

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
    guard let model = conversations.existingModel(for: id) else { return }
    let notice = signInNotice(for: id)
    if model.signIn != notice { model.signIn = notice }
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
    switch signIns[provider] {
    case .running?:
      return ConversationSignIn(agentName: name, state: .signingIn)
    case .failed(let detail, let at)? where at > request.receivedAt:
      return ConversationSignIn(agentName: name, state: .failed(detail: detail))
    case .failed?, nil:
      if let signedIn = signedInAt[provider], signedIn > request.receivedAt {
        return ConversationSignIn(
          agentName: name,
          state: .signedIn(
            canResume: canRestartInPlace(id), textWaiting: signInTextWaiting.contains(id)))
      }
      return ConversationSignIn(agentName: name, state: .expired)
    }
  }
}
