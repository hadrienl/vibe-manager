import Foundation
import VibeApplication
import VibeDomain

/// The consent asked before Vibe Manager approves a CLI's hooks on the user's behalf (#45).
public struct HookConsentRequest: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let agentName: String
  /// What the hooks run, shown before the user decides.
  public let commands: [String]
}

extension AppModel {
  public func activity(for id: SessionID) -> AgentActivityState? {
    activities[id]
  }

  /// Subscribes to the tracker, then reads back what the last launch left unread.
  func startFollowingActivity() async {
    guard let activityTracker, activityUpdates == nil else { return }
    let updates = await activityTracker.updates()
    activityUpdates = Task { [weak self] in
      for await update in updates {
        guard let self else { return }
        self.activities[update.sessionID] = update.state
        self.conversations.activityChanged(update.sessionID, to: update.state)
      }
    }
    await activityTracker.load()
    activities = await activityTracker.states()
    await loadHookTrustingAgents()
    updateVisibleSession()
  }

  /// The main window was hidden, minimised or covered — or shown again.
  public func mainWindowVisibilityChanged(_ isVisible: Bool) {
    guard isMainWindowVisible != isVisible else { return }
    isMainWindowVisible = isVisible
    updateVisibleSession()
  }

  /// The session in front of the user, if any: selected, in a window on screen, in the active
  /// application. A sheet over the window does not hide it.
  func updateVisibleSession() {
    guard let activityTracker else { return }
    let visible = isApplicationActive && isMainWindowVisible ? selectedSessionID : nil
    Task { await activityTracker.setVisibleSession(visible) }
  }

  // MARK: - Consent

  /// Shows the consent sheet, or joins the one already shown: every launch waiting on it gets the
  /// same answer. A launch cancelled while it waits — a restoration called off on quit — gets no
  /// answer, which nothing remembers.
  func requestHookConsent(agentName: String, commands: [String]) async -> AgentHookConsent {
    let key = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: .undecided)
          return
        }
        hookConsentWaiters[key] = continuation
        if hookConsentRequest == nil {
          hookConsentRequest = HookConsentRequest(agentName: agentName, commands: commands)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.settleHookConsent(key, .undecided) }
    }
  }

  private func settleHookConsent(_ key: UUID, _ answer: AgentHookConsent) {
    guard let continuation = hookConsentWaiters.removeValue(forKey: key) else { return }
    if hookConsentWaiters.isEmpty { hookConsentRequest = nil }
    continuation.resume(returning: answer)
  }

  /// The buttons of the sheet give `approved` or `declined`; closing it otherwise is `undecided`.
  public func answerHookConsent(_ answer: AgentHookConsent) {
    hookConsentRequest = nil
    let waiters = hookConsentWaiters
    hookConsentWaiters = [:]
    for continuation in waiters.values { continuation.resume(returning: answer) }
    Task { await loadHookTrustingAgents() }
  }

  // MARK: - Setting

  func loadHookTrustingAgents() async {
    guard let agents else { return }
    var trusting: [AgentDescriptor] = []
    for descriptor in await agents.descriptors() {
      if await agents.provider(id: descriptor.id) is any AgentHookTrusting {
        trusting.append(descriptor)
      }
    }
    hookTrustingAgents = trusting
    reportsActivity = Dictionary(
      uniqueKeysWithValues: trusting.map { ($0.id, !hookConsents.isDeclined($0.id)) })
  }

  /// Turned back on, the next launch of that agent asks again; turned off, its agents run
  /// without hooks from their next launch.
  public func setReportsActivity(_ reports: Bool, for provider: AgentProviderID) {
    hookConsents.setDeclined(!reports, for: provider)
    reportsActivity[provider] = reports
  }
}
