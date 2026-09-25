import Foundation
import Observation
import VibeApplication
import VibeConversationUI
import VibeDomain

/// The conversation views of the workspace (#38): the settings they share, and one model per
/// session recently shown.
///
/// Only the last few sessions shown in conversation keep a model — and read their transcripts —
/// so that going back and forth between two of them is instant, while a hundred sessions never
/// mean a hundred readers. A model let go of gives its memory back; it is rebuilt when shown again.
@MainActor
@Observable
public final class ConversationWorkspace {
  /// How many sessions keep their conversation read and laid out.
  static let keptModelCount = 5

  public struct Agent: Sendable {
    public let name: String
    public let format: AgentPromptFormat
  }

  @ObservationIgnored private let follow: FollowConversation?
  @ObservationIgnored private let store: any ConversationAppearanceStore
  @ObservationIgnored private let agents: (any AgentProviderResolving)?

  public var appearance: ConversationAppearance {
    didSet {
      guard appearance != oldValue else { return }
      store.appearance = appearance
      for model in models.values { model.appearance = appearance }
    }
  }

  /// The providers whose transcripts can be read, by provider identifier.
  public private(set) var readableAgents: [String: Agent] = [:]
  private var models: [SessionID: ConversationModel] = [:]
  /// Most recent last.
  public private(set) var mountedSessionIDs: [SessionID] = []
  @ObservationIgnored private var followed: [SessionID: [SessionAgentConfiguration]] = [:]
  /// Which follow is the current one for a session: a stream that arrives after its model was
  /// let go of, or after a newer one was asked for, is dropped — and stops its reader with it.
  @ObservationIgnored private var generations: [SessionID: Int] = [:]

  /// Hooks the models up to the session's terminal: writing to it, reading whether it runs,
  /// bringing it forward.
  @ObservationIgnored var connect: ((ConversationModel, WorkSession) -> Void)?

  public init(
    follow: FollowConversation? = nil,
    store: any ConversationAppearanceStore = InMemoryConversationAppearanceStore(),
    agents: (any AgentProviderResolving)? = nil
  ) {
    self.follow = follow
    self.store = store
    self.agents = agents
    appearance = store.appearance
  }

  /// Learns which agents write a transcript the view can read.
  public func prepare() async {
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
    }
    let agent = session.conversationAgents.last.flatMap { readableAgents[$0.providerID] }
    model.agentName = agent?.name ?? ""
    model.promptFormat = agent?.format ?? AgentPromptFormat()
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

  /// The model if one is kept, without creating it.
  public func existingModel(for id: SessionID) -> ConversationModel? {
    models[id]
  }

  public func activityChanged(_ id: SessionID, to activity: AgentActivity?) {
    models[id]?.activity = activity
  }

  /// A session was archived, closed for good or forgotten.
  public func release(_ id: SessionID) {
    models.removeValue(forKey: id)?.stop()
    followed[id] = nil
    generations[id] = nil
    // What was said lives only as long as a view shows it (ADR 0023).
    MarkdownCache.shared.removeAll()
    mountedSessionIDs.removeAll { $0 == id }
  }

  private func evict() {
    while mountedSessionIDs.count > Self.keptModelCount {
      release(mountedSessionIDs.removeFirst())
    }
  }
}
