import Foundation
import Observation
import VibeApplication
import VibeConversationUI
import VibeDomain

/// The conversation views of the workspace (#38): the settings they share, and one model per
/// session recently shown.
///
/// Only the last few sessions shown in conversation keep a view mounted and read their transcripts,
/// so that going back and forth between two of them is instant, while a hundred sessions never
/// mean a hundred readers. A few more keep what was read, and nothing else: coming back to one
/// shows its conversation at once while its transcripts are read again, instead of a placeholder
/// for as long as that takes. Past those, a model is let go of and gives its memory back.
@MainActor
@Observable
public final class ConversationWorkspace {
  /// How many sessions keep their conversation read and laid out.
  static let keptModelCount = 5
  /// How many more keep what was read, no longer read nor laid out.
  static let dormantModelCount = 20

  public struct Agent: Sendable {
    public let name: String
    public let format: AgentPromptFormat
    /// Lists what a prompt may invoke; `nil` for an agent that cannot (#219).
    public var commands: (any AgentCommandListing)? = nil
  }

  @ObservationIgnored private let follow: FollowConversation?
  @ObservationIgnored private let store: any ConversationAppearanceStore
  @ObservationIgnored private let agents: (any AgentProviderResolving)?
  /// The skills and commands read from the agents, shared by the sessions of a folder (#219).
  @ObservationIgnored let commands: AgentCommandCatalog
  /// Which list each model reads: another agent or folder starts from an empty one.
  @ObservationIgnored private var commandKeys: [SessionID: AgentCommandCatalog.Key] = [:]
  /// Initial commands typed before their conversation was first shown.
  @ObservationIgnored private var typedCommands: [SessionID: (command: String, at: Date)] = [:]
  /// The user's own themes, and the one on trial (#118).
  public let themes: ConversationThemesModel

  public var appearance: ConversationAppearance {
    didSet {
      guard appearance != oldValue else { return }
      store.appearance = appearance
      for model in models.values { model.appearance = appearance }
    }
  }

  /// The providers whose transcripts can be read, by provider identifier.
  public internal(set) var readableAgents: [String: Agent] = [:]
  private var models: [SessionID: ConversationModel] = [:]
  /// Most recent last.
  public private(set) var mountedSessionIDs: [SessionID] = []
  /// Sessions whose model is kept without a view nor a reader, most recent last.
  @ObservationIgnored private var dormantSessionIDs: [SessionID] = []
  /// The last activity of a dormant session, handed to its model when it is shown again rather
  /// than rebuilding a conversation nobody sees at every change.
  @ObservationIgnored private var dormantActivities: [SessionID: AgentActivityState?] = [:]
  @ObservationIgnored private var followed: [SessionID: [SessionAgentConfiguration]] = [:]
  /// The session as last told to its follow when its conversations changed: a change heard while
  /// the follow was still being set up had no follow to reach, and is told again once it exists.
  @ObservationIgnored private var changedSessions: [SessionID: WorkSession] = [:]
  /// The last activity of each followed session, to tell a turn that starts from one that goes on.
  @ObservationIgnored private var activities: [SessionID: AgentActivityState?] = [:]
  /// Which follow is the current one for a session: a stream that arrives after its model was
  /// let go of, or after a newer one was asked for, is dropped — and stops its reader with it.
  @ObservationIgnored private var generations: [SessionID: Int] = [:]

  /// A session whose composer was asked for the keyboard before its model existed (#105): the
  /// model is only made once the view that shows it asks, after the switch that asked.
  @ObservationIgnored private var pendingComposerFocus: SessionID?

  /// Hooks the models up to the session's terminal: writing to it, reading whether it runs,
  /// bringing it forward.
  @ObservationIgnored var connect: ((ConversationModel, WorkSession) -> Void)?

  public init(
    follow: FollowConversation? = nil,
    store: any ConversationAppearanceStore = InMemoryConversationAppearanceStore(),
    agents: (any AgentProviderResolving)? = nil,
    themes: ConversationThemesModel = ConversationThemesModel(),
    commands: AgentCommandCatalog = AgentCommandCatalog()
  ) {
    self.follow = follow
    self.store = store
    self.agents = agents
    self.commands = commands
    self.themes = themes
    appearance = store.appearance
  }

  /// Learns which agents write a transcript the view can read.
  public func prepare() async {
    // The user's own themes first: a conversation drawn with one of them needs it at launch, not
    // only once the settings are opened (#118).
    await themes.load()
    await refreshReadableAgents()
  }

  /// Learns again which agents can be read: the endpoints (#107) come and go with the settings.
  public func refreshReadableAgents() async {
    guard follow != nil, let agents else { return }
    var readable: [String: Agent] = [:]
    for descriptor in await agents.descriptors() {
      guard let provider = await agents.provider(id: descriptor.id),
        let reporting = provider as? any AgentConversationReporting
      else { continue }
      readable[descriptor.id.rawValue] = Agent(
        name: descriptor.displayName, format: reporting.promptFormat,
        commands: provider as? any AgentCommandListing)
    }
    readableAgents = readable
  }

  /// Whether the session has a conversation the view can show.
  public func canShowConversation(_ session: WorkSession) -> Bool {
    session.conversationAgents.contains { readableAgents[$0.providerID] != nil }
  }

  /// Readies the session's model: created — and its transcripts followed — the first time, and
  /// moved to the front of those kept. Not for a view's body: it changes what is observed.
  @discardableResult
  public func show(_ session: WorkSession) -> ConversationModel {
    let model: ConversationModel
    let isNew = models[session.id] == nil
    if let existing = models[session.id] {
      model = existing
    } else {
      model = ConversationModel(sessionID: session.id)
      model.appearance = appearance
      if let follow {
        let id = session.id
        model.unfoldSubagents = { callIDs in
          Task { await follow.setUnfoldedSubagents(callIDs, for: id) }
        }
        model.agentRunningChanged = { isRunning, startedAt in
          Task { await follow.setAgentRunning(isRunning, since: startedAt, for: id) }
        }
        // Mounted but hidden, a conversation is still read, and published less often (#250).
        model.shownChanged = { isShown, order in
          Task { await follow.setShown(isShown, for: id, order: order) }
        }
      }
      models[session.id] = model
      connect?(model, session)
      // Its initial command typed a moment before the conversation was first shown.
      if let typed = typedCommands.removeValue(forKey: session.id),
        Date().timeIntervalSince(typed.at) < 5
      {
        model.expectTerminalPanel(forInitialPrompt: typed.command)
      }
      if pendingComposerFocus == session.id {
        pendingComposerFocus = nil
        model.requestComposerFocus()
      }
    }
    if let state = dormantActivities.removeValue(forKey: session.id) {
      apply(state, to: model)
    }
    dormantSessionIDs.removeAll { $0 == session.id }
    let conversation = session.conversationAgents.last
    let agent = conversation.flatMap { readableAgents[$0.providerID] }
    model.agentName = agent?.name ?? ""
    model.promptFormat = agent?.format ?? AgentPromptFormat()
    connectCommands(of: model, agent: agent, providerID: conversation?.providerID, in: session)
    // Where the agent runs: the worktree of a session that has one.
    model.workingDirectoryName =
      RestartSession.workingDirectoryPath(of: session).map {
        URL(fileURLWithPath: $0).lastPathComponent
      } ?? ""
    if let known = followed[session.id], known != session.conversationAgents, let follow {
      // Already followed: the follow adopts the session as it is now, and keeps what it read
      // rather than reading every transcript again from its start (#255).
      followed[session.id] = session.conversationAgents
      changedSessions[session.id] = session
      Task { await follow.sessionChanged(session) }
    } else if followed[session.id] == nil, let follow {
      followed[session.id] = session.conversationAgents
      changedSessions[session.id] = nil
      let generation = (generations[session.id] ?? 0) + 1
      generations[session.id] = generation
      let id = session.id
      // Told before the first reading: the sub-agents of a session whose agent stopped, or that an
      // earlier process of it left, are not opened, and a new model starts with everything folded
      // (#180).
      let isAgentRunning = model.isProcessRunning
      let (isShown, shownOrder) = (model.isShown, model.shownOrder)
      Task { [weak self] in
        let startedAt = isAgentRunning ? await model.processStartDate() : nil
        await follow.setAgentRunning(isAgentRunning, since: startedAt, for: id)
        // What the reader was told last about a model since let go of is no longer true.
        await follow.setShown(isShown, for: id, order: shownOrder)
        if isNew { await follow.setUnfoldedSubagents([], for: id) }
        let stream = await follow.follow(session)
        guard let self, self.generations[id] == generation, self.models[id] === model else {
          return
        }
        if let changed = self.changedSessions[id],
          changed.conversationAgents != session.conversationAgents
        {
          await follow.sessionChanged(changed)
        }
        model.follow(stream)
      }
    }
    mountedSessionIDs.removeAll { $0 == session.id }
    mountedSessionIDs.append(session.id)
    evict()
    return model
  }

  /// A session's initial command was typed into its agent (#219): its conversation looks for the
  /// panel the command may open — now, or if it is first shown in the next few seconds.
  public func commandTyped(_ command: String, in id: SessionID) {
    if let model = models[id] {
      model.expectTerminalPanel(forInitialPrompt: command)
    } else {
      typedCommands[id] = (command, Date())
    }
  }

  /// Hands the model what its agent accepts under `/`, read where the agent runs (#219): read
  /// once the conversation is first shown, then each time the list opens.
  private func connectCommands(
    of model: ConversationModel, agent: Agent?, providerID: String?, in session: WorkSession
  ) {
    guard let listing = agent?.commands, let providerID,
      let directory = RestartSession.workingDirectoryPath(of: session)
    else {
      commandKeys[session.id] = nil
      model.readCommands = nil
      return
    }
    let key = AgentCommandCatalog.Key(
      providerID: AgentProviderID(providerID), workingDirectoryPath: directory)
    guard commandKeys[session.id] != key || model.readCommands == nil else { return }
    commandKeys[session.id] = key
    let catalog = commands
    // Emptied first: the list of the agent before is not this one's.
    model.readCommands = nil
    model.readCommands = { await catalog.refreshed(key, from: listing) }
    model.refreshCommands()
  }

  /// Asks for the session's composer to take the keyboard, now or as soon as its model exists.
  /// False when the composer is known to be closed: nothing would take the keyboard.
  @discardableResult
  public func requestComposerFocus(for id: SessionID) -> Bool {
    guard let model = models[id] else {
      pendingComposerFocus = id
      return true
    }
    pendingComposerFocus = nil
    guard model.acceptsInput else { return false }
    model.requestComposerFocus()
    return true
  }

  /// A request still waiting for a model is dropped once the user is elsewhere.
  func cancelPendingComposerFocus(unless id: SessionID?) {
    if pendingComposerFocus != id { pendingComposerFocus = nil }
  }

  /// The model if one is kept, without creating it.
  public func existingModel(for id: SessionID) -> ConversationModel? {
    models[id]
  }

  /// The sessions as the application now holds them: a follow whose session gained or changed a
  /// conversation — a switch of agent, an identifier learned — adopts it, whether it is on screen
  /// or not (#255).
  public func sessionsChanged(_ sessions: [WorkSession]) {
    guard let follow, !followed.isEmpty else { return }
    for session in sessions {
      guard let known = followed[session.id], known != session.conversationAgents else {
        continue
      }
      followed[session.id] = session.conversationAgents
      changedSessions[session.id] = session
      Task { await follow.sessionChanged(session) }
    }
  }

  public func activityChanged(_ id: SessionID, to state: AgentActivityState?) {
    // A turn that starts, or hooks that speak for the first time, may come with a new transcript:
    // after a `/clear`, the next prompt writes a new file (#255).
    if followed[id] != nil, let follow {
      let previous = activities.updateValue(state, forKey: id) ?? nil
      if Self.mayStartTranscript(from: previous, to: state) {
        Task { await follow.lookAgain(for: id) }
      }
    }
    guard let model = models[id] else { return }
    if dormantSessionIDs.contains(id) {
      dormantActivities[id] = .some(state)
    } else {
      apply(state, to: model)
    }
  }

  static func mayStartTranscript(from previous: AgentActivityState?, to state: AgentActivityState?)
    -> Bool
  {
    guard let state else { return false }
    return (state.activity == .working && previous?.activity != .working)
      || state.source != previous?.source
  }

  private func apply(_ state: AgentActivityState?, to model: ConversationModel) {
    model.activity = state?.activity
    model.isAgentReady = Self.isReady(state)
    model.processStateChanged()
  }

  /// Ready once the agent's hooks have spoken, or once the activity falls back on the terminal's
  /// output for an agent whose hooks never do.
  static func isReady(_ state: AgentActivityState?) -> Bool {
    guard let state else { return true }
    if case .unconfirmed = state.source { return false }
    return true
  }

  /// A session was archived, closed for good or forgotten.
  public func release(_ id: SessionID) {
    models.removeValue(forKey: id)?.stop()
    // What its readers kept aside to resume goes with the model.
    if let follow { Task { await follow.forget(id) } }
    followed[id] = nil
    changedSessions[id] = nil
    generations[id] = nil
    activities[id] = nil
    commandKeys[id] = nil
    dormantSessionIDs.removeAll { $0 == id }
    dormantActivities[id] = nil
    if pendingComposerFocus == id { pendingComposerFocus = nil }
    // What was said lives only as long as a model holds it (ADR 0025).
    MarkdownCache.shared.removeAll()
    mountedSessionIDs.removeAll { $0 == id }
  }

  private func evict() {
    while mountedSessionIDs.count > Self.keptModelCount {
      let id = mountedSessionIDs.removeFirst()
      models[id]?.pause()
      // Followed again when shown, its readers resuming where they stopped (#249): a follow
      // still being set up is dropped.
      followed[id] = nil
      changedSessions[id] = nil
      activities[id] = nil
      generations[id] = (generations[id] ?? 0) + 1
      dormantSessionIDs.append(id)
    }
    while dormantSessionIDs.count > Self.dormantModelCount {
      release(dormantSessionIDs.removeFirst())
    }
  }
}
