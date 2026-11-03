import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain

/// Where a sign-in started from a conversation stands (#410).
public enum AgentSignInProgress: Equatable, Sendable {
  case running
  /// What the CLI said, and when: a session stopped on its sign-in after that is a new expiry.
  case failed(detail: String?, at: Date)
  /// Signed in, to another account than this agent's (#478): nothing resumes until the user says.
  case otherAccount(expected: String, actual: String)
}

/// The address of the account each agent is signed in to (#478). Only the address: the sign-in
/// itself is the CLI's.
public final class SignedInAccountMemory: @unchecked Sendable {
  private let defaults: UserDefaults?
  private var inMemory: [String: String] = [:]
  private static let key = "agentSignedInAccounts"

  /// - Parameter defaults: `nil` keeps them for this run only, for the tests.
  public init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
  }

  private var all: [String: String] {
    get { defaults?.dictionary(forKey: Self.key) as? [String: String] ?? inMemory }
    set {
      inMemory = newValue
      defaults?.set(newValue, forKey: Self.key)
    }
  }

  public func account(of provider: AgentProviderID) -> String? { all[provider.rawValue] }
  public func remember(_ account: String?, of provider: AgentProviderID) {
    all[provider.rawValue] = account
  }
}

/// The CLI's sign-in expired (#410): signed in again from the conversation, in the browser, once
/// for every session of that agent — and each session it had stopped is restarted, its
/// conversation resumed, and handed back the prompt that failed.
extension AppModel {
  /// The agents whose page of the settings offers the sign-in, whatever their state: a CLI can say
  /// it is signed in with a token that expired, and an account may be changed at will.
  func loadSigningAgents() async {
    guard let agents else { return }
    var signing: Set<AgentProviderID> = []
    for descriptor in await agents.descriptors()
    where await agents.provider(id: descriptor.id) is any AgentSigningIn {
      signing.insert(descriptor.id)
    }
    agentsSigningIn = signing
  }

  public func loadSigningInAgents() async {
    guard let agents else { return }
    var signing: Set<AgentProviderID> = []
    for descriptor in await agents.descriptors()
    {
      guard let provider = await agents.provider(id: descriptor.id) as? any AgentSigningIn,
        provider.signsInFromConversations
      else { continue }
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
      signInRoutes[provider]?.route == .browser || isOnOtherAccount(provider)
    else { return }
    signIn(agent: provider)
  }

  /// Signs an agent in from its page of the settings, or from one of its conversations.
  public func signIn(agent provider: AgentProviderID) {
    guard signInTasks[provider] == nil, let agents else { return }
    // A second try after the wrong account: the CLI still holds it, and it is what comes back
    // should this one be cancelled or fail.
    let pending = signIns[provider]
    var wanted: String?
    if case .otherAccount(let expected, _)? = pending { wanted = expected }
    signIns[provider] = .running
    publishSignIns()
    signInTasks[provider] = Task { [weak self] in
      let signing = await agents.provider(id: provider) as? any AgentSigningIn
      // Read before: an expired sign-in still names its account, even one changed outside.
      let before = wanted == nil ? await signing?.signedInAccount() : wanted
      let outcome = await signing?.signIn() ?? .notSignedIn(detail: nil)
      let after = outcome == .signedIn ? await signing?.signedInAccount() : nil
      guard let self else { return }
      // Nor is an account that cannot be read a sign that the alert was answered.
      if wanted != nil, outcome != .signedIn || after == nil {
        self.signInTasks[provider] = nil
        self.signIns[provider] = pending
        self.publishSignIns()
        return
      }
      await self.signInEnded(provider, outcome: outcome, before: before, after: after)
    }
  }

  private func isOnOtherAccount(_ provider: AgentProviderID) -> Bool {
    if case .otherAccount? = signIns[provider] { return true }
    return false
  }

  public func cancelSignIn(agent provider: AgentProviderID) {
    signInTasks[provider]?.cancel()
  }

  /// The account signed in is the one wanted after all: its sessions resume.
  public func keepSignedInAccount(of provider: AgentProviderID) {
    guard case .otherAccount(_, let actual)? = signIns[provider] else { return }
    signedInAccounts.remember(actual, of: provider)
    signedInAddresses[provider] = actual
    signIns[provider] = nil
    signedInAt[provider] = Date()
    Task { await resumeSessionsSignedIn(provider) }
  }

  /// Asks the CLI which account it uses, for the agent's page.
  public func refreshSignedInAccount(of provider: AgentProviderID) async {
    guard let agents,
      let signing = await agents.provider(id: provider) as? any AgentSigningIn
    else { return }
    // A key or a provider set outside the CLI is not signed in again from the page.
    signInRoutes[provider] = (await signing.signInRoute(), Date())
    let address = await signing.signedInAccount()
    // A sign-in under way has the last word: it reads the account when it ends.
    guard signInTasks[provider] == nil else { return }
    signedInAddresses[provider] = address
    // Changed outside — `claude auth login`, `/login` — it is the user's: only a pending alert
    // still waits for an answer.
    if let address, !isOnOtherAccount(provider) {
      signedInAccounts.remember(address, of: provider)
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

  func signInEnded(
    _ provider: AgentProviderID, outcome: AgentSignInOutcome, before: String? = nil,
    after: String? = nil
  ) async {
    signInTasks[provider] = nil
    switch outcome {
    case .signedIn:
      let expected = before ?? signedInAccounts.account(of: provider)
      signedInAddresses[provider] = after
      if let expected, let after, expected.caseInsensitiveCompare(after) != .orderedSame {
        // The first prompt it would be handed goes to the wrong account: nothing resumes.
        signedInAccounts.remember(expected, of: provider)
        signIns[provider] = .otherAccount(expected: expected, actual: after)
        publishSignIns()
        await refreshAgents(forceRefresh: false)
        return
      }
      if let after { signedInAccounts.remember(after, of: provider) }
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
    await resumeSessionsSignedIn(provider)
  }

  private func resumeSessionsSignedIn(_ provider: AgentProviderID) async {
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
    case .otherAccount(let expected, let actual)?:
      return ConversationSignIn(
        agentName: name, state: .otherAccount(expected: expected, actual: actual), route: route)
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
