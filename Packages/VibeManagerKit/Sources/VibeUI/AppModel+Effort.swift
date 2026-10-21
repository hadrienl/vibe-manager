import Foundation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// What the status bar's menu of reasoning effort shows for a session (#411).
public struct SessionEffortMenu: Equatable, Sendable {
  /// The levels its agent takes, lowest first.
  public var levels: [String]
  /// The level in force, `nil` for the agent's own default.
  public var current: String?
  /// Whether "Default" is one of the choices.
  public var offersDefault: Bool
  /// A level being given to the agent: the menu waits for it.
  public var isApplying = false
}

extension AppModel {
  public func effortMenu(for id: SessionID) -> SessionEffortMenu? {
    effortCells.value(for: id)
  }

  /// Reads again what the session's agent says of its effort, and the levels it takes. An agent
  /// whose effort cannot be changed from here has no menu.
  func refreshEffort(of id: SessionID) async {
    guard let session = session(withID: id), let agent = session.agent,
      let provider = await agents?.provider(id: AgentProviderID(agent.providerID))
        as? any AgentEffortControlling
    else {
      effortCells.set(nil, for: id)
      return
    }
    let report = await provider.effortReport(
      resumeIdentifier: agent.resumeIdentifier, since: session.createdAt)
    let levels = await provider.effortLevels(modelID: agent.modelID ?? report.modelID)
    // What the transcript said before the process was started — with the level kept — or before
    // a level was given from here, is out of date.
    var said = report.effort
    let cutoff = [effortGivenAt[id], launcher?.launchDate(of: id)].compactMap(\.self).max()
    if let cutoff, (report.saidAt ?? .distantPast) < cutoff { said = nil }
    // A level set by hand in the terminal is the one kept for the next launch, as one chosen
    // here. The agent's own default, said while none is kept, stays its default: a later change
    // of its settings still applies.
    if let said, said != agent.effort, agent.effort != nil || said != report.configuredEffort {
      await keepEffort(said, providerID: agent.providerID, of: id)
    }
    var menu = SessionEffortMenu(
      levels: levels, current: said ?? agent.effort ?? report.configuredEffort,
      offersDefault: provider.offersDefaultEffort)
    // A level it says it runs with is offered even when the cache does not list it.
    if let current = menu.current, !menu.levels.contains(current) { menu.levels.append(current) }
    menu.isApplying = effortCells.value(for: id)?.isApplying ?? false
    effortCells.set(menu, for: id)
  }

  /// A turn ended: Codex wrote the level it ran with, set by hand in the terminal perhaps.
  func effortActivityChanged(
    _ id: SessionID, from previous: AgentActivityState?, to state: AgentActivityState
  ) {
    guard effortCells.value(for: id) != nil, previous?.activity == .working,
      state.activity != .working
    else { return }
    Task { [weak self] in await self?.refreshEffort(of: id) }
  }

  /// Whether the menu can be used now: the agent runs and is at rest at its prompt.
  public func canChangeEffort(of id: SessionID) -> Bool {
    guard launcher?.isRunning(id) == true, effortMenu(for: id)?.isApplying == false else {
      return false
    }
    switch activity(for: id)?.activity {
    case .working, .awaitingUser: return false
    case .idle, nil: return true
    }
  }

  /// Gives the session's agent a level, `nil` for its default, as the user would type it: the
  /// command, or the panel and its keys. Only at rest, never while the user types: it beeps
  /// otherwise. Kept on the session for its next launches once the agent has it.
  public func setEffort(_ level: String?, for id: SessionID) {
    guard var menu = effortMenu(for: id), menu.current != level, canChangeEffort(of: id) else {
      return
    }
    menu.isApplying = true
    effortCells.set(menu, for: id)
    Task { [weak self] in
      guard let self else { return }
      let applied = await self.applyEffort(level, to: id)
      if var menu = self.effortMenu(for: id) {
        menu.isApplying = false
        if applied { menu.current = level }
        self.effortCells.set(menu, for: id)
      }
      if !applied { self.beep() }
    }
  }

  private func applyEffort(_ level: String?, to id: SessionID) async -> Bool {
    guard let agent = session(withID: id)?.agent,
      let provider = await agents?.provider(id: AgentProviderID(agent.providerID))
        as? any AgentEffortControlling,
      let change = provider.effortChange(to: level)
    else { return false }
    // Taken before the checks, as a message of a coordinator: the two never interleave.
    guard coordination.typing.insert(id).inserted else { return false }
    defer { coordination.typing.remove(id) }
    guard await canTypeCoordinationMessage(into: id) else { return false }
    // A key the user types meanwhile would go with the application's: it gives up.
    let begun = ContinuousClock.now
    let applied: Bool
    switch change {
    case .command(let command):
      applied = await typeEffortCommand(command, into: id, begun: begun)
    case .panel(let opening, let driver):
      let opened = await typeEffortCommand(opening, into: id, begun: begun)
      applied = opened ? await drive(driver, in: id, begun: begun) : false
    }
    guard applied else { return false }
    effortGivenAt[id] = Date()
    diagnostics.record(
      .session, .info, "session.effortChanged",
      [
        "session": diagnostics.pseudonym(id),
        "provider": .token(AgentProviderID(agent.providerID).diagnosticToken),
      ])
    await keepEffort(level, providerID: agent.providerID, of: id)
    return true
  }

  /// Writes the level on the session, for its next launches.
  private func keepEffort(_ effort: String?, providerID: String, of id: SessionID) async {
    guard
      (try? await recordAgentEffort(sessionID: id, providerID: providerID, effort: effort))
        != nil
    else { return }
    showAgentEffort(effort, providerID: providerID, of: id)
  }

  /// Types a command as the keyboard would — never pasted: a pasted `/model` is text to Codex,
  /// not its command — and submits it if the agent is still at rest once it is in.
  private func typeEffortCommand(
    _ command: String, into id: SessionID, begun: ContinuousClock.Instant
  ) async -> Bool {
    guard let pane = pane(for: id), pane.status == .running, let terminal = pane.session else {
      return false
    }
    await pane.write(Array(command.utf8))
    // The list of commands the CLI draws under a `/` comes before Return picks one.
    try? await Task.sleep(for: Self.effortCommandSettle)
    var isAtRest: Bool {
      switch activity(for: id)?.activity {
      case .working, .awaitingUser: false
      case .idle, nil: true
      }
    }
    guard pane.session === terminal else { return false }
    guard isAtRest, !Self.typed(in: pane, since: begun) else {
      // Left in the prompt, unsent, for the user to see: never submitted behind their back.
      diagnostics.record(
        .session, .notice, "session.effortCommandLeftInInput",
        ["session": diagnostics.pseudonym(id)])
      return false
    }
    await pane.write([0x0D])
    return true
  }

  private static func typed(in pane: TerminalPaneModel, since begun: ContinuousClock.Instant)
    -> Bool
  {
    pane.lastKeyboardInputAt.map { $0 > begun } ?? false
  }

  static let effortCommandSettle = Duration.milliseconds(300)

  /// How long a panel is driven before it is given up and closed.
  static let effortPanelLimit = Duration.seconds(8)

  /// Reads the panel the command opened and presses what its driver asks, a screen at a time:
  /// after each key, the screen it acted on must have been drawn again before it is read. A panel
  /// it cannot finish — or that the user types into — is closed with Escape, the way the user
  /// would leave it.
  private func drive(
    _ driver: any AgentEffortPanelDriving, in id: SessionID, begun: ContinuousClock.Instant
  ) async -> Bool {
    guard let launcher, let pane = pane(for: id), let terminal = pane.session else { return false }
    let clock = ContinuousClock()
    let deadline = clock.now + Self.effortPanelLimit
    var actedOn: String?
    while clock.now < deadline, !Task.isCancelled, pane.session === terminal,
      !Self.typed(in: pane, since: begun)
    {
      try? await Task.sleep(for: .milliseconds(250))
      guard let screen = await launcher.screen(of: id) else { return false }
      if screen == actedOn { continue }
      switch driver.step(on: screen) {
      case .press(let keys):
        actedOn = screen
        await pane.write(Array(keys.utf8))
      case .finish(let keys):
        guard !Self.typed(in: pane, since: begun) else { break }
        await pane.write(Array(keys.utf8))
        return true
      case .wait:
        continue
      }
    }
    // Escape only where a panel is drawn: at the prompt, Codex reads it as going back in history.
    for _ in 0..<3 {
      guard pane.session === terminal, let screen = await launcher.screen(of: id),
        AgentPanelRecognition.showsPanel(screen: screen)
      else { break }
      await pane.write([0x1B])
      try? await Task.sleep(for: .milliseconds(300))
    }
    diagnostics.record(
      .session, .notice, "session.effortPanelAbandoned", ["session": diagnostics.pseudonym(id)])
    return false
  }
}
