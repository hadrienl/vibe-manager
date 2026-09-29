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
  }

  @ObservationIgnored private let follow: FollowConversation?
  @ObservationIgnored private let store: any ConversationAppearanceStore
  @ObservationIgnored private let agents: (any AgentProviderResolving)?
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
    themes: ConversationThemesModel = ConversationThemesModel()
  ) {
    self.follow = follow
    self.store = store
    self.agents = agents
    self.themes = themes
    appearance = store.appearance
  }

  /// Learns which agents write a transcript the view can read.
  public func prepare() async {
    // The user's own themes first: a conversation drawn with one of them needs it at launch, not
    // only once the settings are opened (#118).
    await themes.load()
    guard follow != nil, let agents else { return }
    var readable: [String: Agent] = [:]
    for descriptor in await agents.descriptors() {
      guard let provider = await agents.provider(id: descriptor.id),
        let reporting = provider as? any AgentConversationReporting
      else { continue }
      readable[descriptor.id.rawValue] = Agent(
        name: descriptor.displayName, format: reporting.promptFormat)
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
    if let existing = models[session.id] {
      model = existing
    } else {
      model = ConversationModel(sessionID: session.id)
      model.appearance = appearance
      models[session.id] = model
      connect?(model, session)
      if pendingComposerFocus == session.id {
        pendingComposerFocus = nil
        model.requestComposerFocus()
      }
    }
    if let state = dormantActivities.removeValue(forKey: session.id) {
      apply(state, to: model)
    }
    dormantSessionIDs.removeAll { $0 == session.id }
    let agent = session.conversationAgents.last.flatMap { readableAgents[$0.providerID] }
    model.agentName = agent?.name ?? ""
    model.promptFormat = agent?.format ?? AgentPromptFormat()
    model.workingDirectoryName =
      session.repositories.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? ""
    if followed[session.id] != session.conversationAgents, let follow {
      followed[session.id] = session.conversationAgents
      let generation = (generations[session.id] ?? 0) + 1
      generations[session.id] = generation
      let id = session.id
      Task { [weak self] in
        let stream = await follow.follow(session)
        guard let self, self.generations[id] == generation, self.models[id] === model else {
          return
        }
        model.follow(stream)
      }
    }
    mountedSessionIDs.removeAll { $0 == session.id }
    mountedSessionIDs.append(session.id)
    evict()
    return model
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

  public func activityChanged(_ id: SessionID, to state: AgentActivityState?) {
    guard let model = models[id] else { return }
    if dormantSessionIDs.contains(id) {
      dormantActivities[id] = .some(state)
    } else {
      apply(state, to: model)
    }
  }

  private func apply(_ state: AgentActivityState?, to model: ConversationModel) {
    model.activity = state?.activity
    model.isAgentReady = Self.isReady(state)
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
    followed[id] = nil
    generations[id] = nil
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
      // Read again from the start when shown: a follow still being set up is dropped.
      followed[id] = nil
      generations[id] = (generations[id] ?? 0) + 1
      dormantSessionIDs.append(id)
    }
    while dormantSessionIDs.count > Self.dormantModelCount {
      release(dormantSessionIDs.removeFirst())
    }
  }
}
