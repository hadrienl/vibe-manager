import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain

/// A CLI updated on disk while sessions still run its previous build (#409): found by comparing
/// the file each agent process runs with the one its executable resolves to now, offered in the
/// conversation, and acted on once nothing would be lost — the agent stopped and its own
/// conversation resumed, in the same pane.
extension AppModel {
  /// How often the CLIs on disk are looked at: a few `stat`s, nothing run.
  static let agentUpdateInterval: Duration = .seconds(30)
  /// How long a session that just went idle is left to draw its prompt before it is read.
  static let agentUpdateSettle: Duration = .seconds(1)

  func startWatchingAgentUpdates() {
    guard agentUpdateWatch == nil else { return }
    agentUpdateWatch = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.agentUpdateInterval)
        guard let model = self else { return }
        await model.checkAgentUpdates()
      }
    }
  }

  /// Looks at the build each running agent runs, and restarts those waiting for it that can be.
  func checkAgentUpdates() async {
    guard let launcher, !stoppedWatchingAgentUpdates else { return }
    var found: [SessionID: AgentUpdate] = [:]
    for (id, processIdentifier) in await launcher.runningProcessIdentifiers() {
      guard let update = agentUpdate(of: id, processIdentifier: processIdentifier) else {
        continue
      }
      found[id] = update
      if agentUpdates[id] != update { agentRefreshOwed = true }
    }
    noteAgentUpdates(found)
    // The detection that knew the previous build is done again: the settings say the version
    // installed, and the next start is planned with it. One already under way would turn it
    // away, and it is owed until it runs.
    if agentRefreshOwed, !isRefreshingAgents {
      agentRefreshOwed = false
      await refreshAgents(forceRefresh: true)
    }
    await restartPendingUpdates()
  }

  /// The update between the build a process runs and the one its agent's executable resolves to.
  func agentUpdate(of id: SessionID, processIdentifier: Int32) -> AgentUpdate? {
    let probe = SystemProcessLivenessProbe()
    guard let provider = agentProvider(of: id),
      let diagnostic = agentDiagnostics.first(where: { $0.providerID == provider }),
      let installation = diagnostic.installation,
      let running = probe.imagePath(of: processIdentifier)
    else { return nil }
    let installed = Self.resolved(installation.executablePath)
    if let update = AgentUpdate.between(running: running, installed: installed) { return update }
    // Another file altogether — `node` running npm's `cli.js` — is replaced where it stands, if
    // at all. Not the very file the process runs: an attribute Gatekeeper writes on it changes
    // its inode too, and would be taken for an update.
    guard running != installed, let changedAt = Self.inodeChange(of: installed),
      let startedAt = probe.startTime(of: processIdentifier)
    else { return nil }
    let version = installation.version.map(String.init(describing:))
    // What the detection said of a file it read before it changed is the build that runs.
    let runningVersion =
      agentUpdates[id]?.runningVersion ?? (diagnostic.probedAt < changedAt ? version : nil)
    return AgentUpdate.replaced(
      changedAt: changedAt, startedAt: startedAt, runningVersion: runningVersion,
      installedVersion: diagnostic.probedAt > changedAt ? version : nil)
  }

  /// When the file's inode last changed: when it was written, whatever date it says it was
  /// modified.
  nonisolated static func inodeChange(of path: String) -> Date? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    let change = info.st_ctimespec
    return Date(
      timeIntervalSince1970: Double(change.tv_sec) + Double(change.tv_nsec) / 1_000_000_000)
  }

  /// The session's process ended or was replaced: what was found of the previous one is gone.
  func forgetAgentUpdate(_ id: SessionID) {
    guard agentUpdates[id] != nil || pendingUpdateRestarts.contains(id) else { return }
    agentUpdates[id] = nil
    pendingUpdateRestarts.remove(id)
    declinedUpdateRestarts[id] = nil
    publishAgentUpdates()
  }

  /// On the way out, for good.
  func stopWatchingAgentUpdates() {
    stoppedWatchingAgentUpdates = true
    agentUpdateWatch?.cancel()
    agentUpdateWatch = nil
    pendingUpdateRestarts = []
  }

  /// Records what was found: a session no longer on an old build is forgotten, and one an
  /// agent's setting restarts on its own is queued.
  func noteAgentUpdates(_ found: [SessionID: AgentUpdate]) {
    if agentUpdates != found { agentUpdates = found }
    let pending = pendingUpdateRestarts.filter { found[$0] != nil }
    declinedUpdateRestarts = declinedUpdateRestarts.filter { found[$0.key] == $0.value }
    var queued = pending
    for (id, update) in found where declinedUpdateRestarts[id] != update && canRestartInPlace(id) {
      if let provider = agentProvider(of: id), restartsAutomaticallyOnUpdate(provider) {
        queued.insert(id)
      }
    }
    if queued != pendingUpdateRestarts { pendingUpdateRestarts = queued }
    publishAgentUpdates()
  }

  // MARK: - Commands

  /// Restarts this session onto its updated CLI: now if nothing would be lost, otherwise as soon
  /// as its agent is done.
  public func restartForUpdate(_ id: SessionID) {
    guard agentUpdates[id] != nil else { return }
    declinedUpdateRestarts[id] = nil
    pendingUpdateRestarts.insert(id)
    publishAgentUpdates()
    Task { await restartForUpdateIfReady(id) }
  }

  /// The same, for every open session whose agent's CLI was updated.
  public func restartAllForUpdate() {
    // Only those the notice counts: a session that could not resume is not restarted at all.
    for id in agentUpdates.keys where canRestartInPlace(id) {
      declinedUpdateRestarts[id] = nil
      pendingUpdateRestarts.insert(id)
    }
    publishAgentUpdates()
    Task { await restartPendingUpdates() }
  }

  /// The restart waiting for this session is dropped. The setting does not queue it again for
  /// the same update.
  public func cancelUpdateRestart(_ id: SessionID) {
    guard pendingUpdateRestarts.remove(id) != nil else { return }
    declinedUpdateRestarts[id] = agentUpdates[id]
    publishAgentUpdates()
  }

  // MARK: - Setting

  public func restartsAutomaticallyOnUpdate(_ provider: AgentProviderID) -> Bool {
    restartsOnAgentUpdate[provider] ?? agentUpdatePreferences.restartsAutomatically(provider)
  }

  /// Turned on, the sessions of that agent already on an old build are queued too.
  public func setRestartsAutomaticallyOnUpdate(_ restarts: Bool, for provider: AgentProviderID) {
    agentUpdatePreferences.setRestartsAutomatically(restarts, for: provider)
    restartsOnAgentUpdate[provider] = restarts
    guard restarts else { return }
    noteAgentUpdates(agentUpdates)
    Task { await restartPendingUpdates() }
  }

  // MARK: - Restarting

  func restartPendingUpdates() async {
    for id in pendingUpdateRestarts {
      await restartForUpdateIfReady(id)
    }
  }

  /// An agent that just went idle may be the one a restart waits for.
  func agentUpdateActivityChanged(_ id: SessionID, to state: AgentActivityState) {
    guard state.activity == .idle, state.requests.isEmpty, pendingUpdateRestarts.contains(id)
    else { return }
    Task { [weak self] in
      try? await Task.sleep(for: Self.agentUpdateSettle)
      await self?.restartForUpdateIfReady(id)
    }
  }

  func restartForUpdateIfReady(_ id: SessionID) async {
    guard let launcher, pendingUpdateRestarts.contains(id), isFreeForUpdateRestart(id) else {
      return
    }
    let screen = await launcher.screen(of: id)
    // Everything asked again after the screen was read: the user may have cancelled, closed the
    // session or started another command in the meantime, and the process may be another one.
    guard pendingUpdateRestarts.contains(id), isFreeForUpdateRestart(id),
      let processIdentifier = await launcher.runningProcessIdentifiers()[id],
      let update = agentUpdate(of: id, processIdentifier: processIdentifier)
    else { return }
    guard isFreeForUpdateRestart(id) else { return }
    let runsSubagents =
      conversations.existingModel(for: id)?.trayItems.contains { !$0.hasEnded } ?? false
    guard
      AgentUpdateRestartReadiness.isReady(
        activity: activity(for: id), screen: screen, runsSubagents: runsSubagents)
    else { return }
    await performUpdateRestart(id, update: update)
  }

  /// No other command is at work on the session, and the restart would resume its conversation.
  /// What the agent is doing is `AgentUpdateRestartReadiness`'s to say.
  func isFreeForUpdateRestart(_ id: SessionID) -> Bool {
    guard let launcher, !stoppedWatchingAgentUpdates, launcher.isRunning(id), restoration == nil
    else { return false }
    return !restartingSessionIDs.contains(id) && !closingSessionIDs.contains(id)
      && pendingRestart?.sessionID != id && pendingSwitch?.sessionID != id
      && canRestartInPlace(id)
  }

  /// Whether the restart would resume the agent's own conversation: never offered otherwise, as
  /// a fresh start would lose it.
  func canRestartInPlace(_ id: SessionID) -> Bool {
    guard let session = sessions.first(where: { $0.id == id }), let agent = session.agent,
      !resumeRefusals.contains(id),
      agentDescriptors.first(where: { $0.id.rawValue == agent.providerID })?
        .capabilities.supportsResume == true,
      let identifier = agent.resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return false }
    return !identifier.isEmpty
  }

  // MARK: - Conversation

  /// Tells each conversation what it shows of an update.
  func publishAgentUpdates() {
    for session in sessions {
      guard let model = conversations.existingModel(for: session.id) else { continue }
      let notice = agentUpdateNotice(for: session.id)
      if model.agentUpdate != notice { model.agentUpdate = notice }
    }
  }

  func agentUpdateNotice(for id: SessionID) -> ConversationAgentUpdate? {
    guard let update = agentUpdates[id], canRestartInPlace(id) else { return nil }
    let provider = agentProvider(of: id)
    let agentName =
      agentDescriptors.first { $0.id == provider }?.displayName
      ?? agentDiagnostics.first { $0.providerID == provider }?.providerName ?? ""
    return ConversationAgentUpdate(
      agentName: agentName,
      runningVersion: update.runningVersion,
      installedVersion: update.installedVersion,
      isPending: pendingUpdateRestarts.contains(id),
      otherSessionCount: agentUpdates.keys.filter { $0 != id && canRestartInPlace($0) }.count)
  }

  // MARK: - Helpers

  private func agentProvider(of id: SessionID) -> AgentProviderID? {
    sessions.first { $0.id == id }?.agent.map { AgentProviderID($0.providerID) }
  }

  /// The file a path names, links followed — as `proc_pidpath` names the file a process runs.
  nonisolated static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }
}
