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

  func requestHookConsent(agentName: String, commands: [String]) async -> Bool {
    // One question at a time: a second launch waiting on the same CLI gets the first answer's
    // effect through the preferences, and is asked only if that answer did not settle it.
    if let pending = hookConsentContinuation {
      hookConsentContinuation = nil
      pending.resume(returning: false)
    }
    return await withCheckedContinuation { continuation in
      hookConsentContinuation = continuation
      hookConsentRequest = HookConsentRequest(agentName: agentName, commands: commands)
    }
  }

  public func answerHookConsent(_ approved: Bool) {
    hookConsentRequest = nil
    let continuation = hookConsentContinuation
    hookConsentContinuation = nil
    continuation?.resume(returning: approved)
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
