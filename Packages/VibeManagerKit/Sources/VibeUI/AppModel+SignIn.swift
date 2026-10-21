import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain

/// Where a sign-in started from a conversation stands (#410).
public enum AgentSignInProgress: Equatable, Sendable {
  case running
  case failed(detail: String?)
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
      signIns[provider] = .failed(detail: detail)
    }
    publishSignIns()
    guard outcome == .signedIn else { return }
    // The settings say so too.
    await refreshAgents(forceRefresh: false)
    let blocked = sessions.map(\.id).filter {
      agentProvider(of: $0) == provider && signInRequest(of: $0) != nil
    }
    await withTaskGroup(of: Void.self) { group in
      for id in blocked {
        group.addTask { await self.resumeSignedIn(id) }
      }
    }
  }

  // MARK: - Resuming

  /// Restarts the session, its conversation resumed — a process started before the sign-in may
  /// not read the account again —, and types the prompt that failed back into it.
  func resumeSignedIn(_ id: SessionID) async {
    guard let launcher, launcher.isRunning(id), signInRequest(of: id) != nil,
      canRestartInPlace(id), resumingAfterSignIn.insert(id).inserted,
      let session = sessions.first(where: { $0.id == id })
    else { return }
    defer {
      resumingAfterSignIn.remove(id)
      publishSignIn(for: id)
    }
    publishSignIn(for: id)
    // What the user typed into the prompt since is theirs: it would go with the process.
    guard let screen = await launcher.screen(of: id),
      AgentUpdateRestartReadiness.promptIsEmpty(screen: screen)
    else { return }
    let prompt = await conversations.entries(of: session).flatMap(
      ConversationEntry.promptFailedOnSignIn(in:))
    guard await restartInPlace(id), let prompt else { return }
    await typeBack(prompt, into: id)
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
    if resumingAfterSignIn.contains(id) {
      return ConversationSignIn(agentName: name, state: .resuming)
    }
    guard let request = signInRequest(of: id) else { return nil }
    switch signIns[provider] {
    case .running?:
      return ConversationSignIn(agentName: name, state: .signingIn)
    case .failed(let detail)?:
      return ConversationSignIn(agentName: name, state: .failed(detail: detail))
    case nil:
      if let signedIn = signedInAt[provider], signedIn > request.receivedAt {
        return ConversationSignIn(
          agentName: name, state: .signedIn(canResume: canRestartInPlace(id)))
      }
      return ConversationSignIn(agentName: name, state: .expired)
    }
  }
}
