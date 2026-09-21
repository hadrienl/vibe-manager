import Foundation
import Observation
import VibeApplication
import VibeDomain

@MainActor
@Observable
public final class NewSessionModel {
  public struct AgentOption: Identifiable, Sendable {
    public let descriptor: AgentDescriptor
    public let availability: AgentAvailability

    public var id: AgentProviderID { descriptor.id }
    public var isUsable: Bool { availability.isUsable }
    public var name: String { descriptor.displayName }
    public var status: String { availability.diagnostic.summary }
    public var remediations: [AgentRemediation] { availability.diagnostic.remediations }

    /// Usable, yet worth a warning: the CLI runs, and asks for credentials itself in the
    /// terminal. Hiding that would make the first screen of the session a surprise.
    public var warnsBeforeLaunch: Bool {
      availability.state == .unauthenticated
    }
  }

  public private(set) var agents: [AgentOption] = []
  public private(set) var models: [AgentModel] = []
  public private(set) var issues: [SessionDraftIssue] = []
  public private(set) var isSubmitting = false
  public private(set) var isLoadingAgents = false
  /// Problems are shown once the user has asked for the session, then kept live: a form that
  /// turns red while the first character is being typed is a form that nags.
  public private(set) var hasSubmitted = false

  public var draft = SessionDraft() {
    didSet {
      guard oldValue != draft else { return }
      if oldValue.providerID != draft.providerID {
        draft.modelID = nil
        Task { await loadModels() }
      }
      guard hasSubmitted else { return }
      Task { await revalidate() }
    }
  }

  private let create: CreateSession
  private let registry: any AgentProviderResolving

  public init(create: CreateSession, registry: any AgentProviderResolving) {
    self.create = create
    self.registry = registry
  }

  public var selectedAgent: AgentOption? {
    guard let providerID = draft.providerID else { return nil }
    return agents.first { $0.id.rawValue == providerID }
  }

  public var canSubmit: Bool {
    !isSubmitting && !draft.trimmedName.isEmpty && draft.resolvedWorkingDirectoryPath != nil
  }

  public func issues(for field: SessionDraftField) -> [SessionDraftIssue] {
    issues.filter { $0.field == field }
  }

  public func load(defaultWorkingDirectoryPath: String?) async {
    if draft.workingDirectoryPath == nil {
      draft.workingDirectoryPath = defaultWorkingDirectoryPath
    }
    await refreshAgents(forceRefresh: false)
  }

  public func refreshAgents(forceRefresh: Bool) async {
    guard !isLoadingAgents else { return }
    isLoadingAgents = true
    defer { isLoadingAgents = false }

    let descriptors = await registry.descriptors()
    let availabilities = await registry.availabilities(forceRefresh: forceRefresh)
    agents = descriptors.compactMap { descriptor in
      availabilities[descriptor.id].map {
        AgentOption(descriptor: descriptor, availability: $0)
      }
    }

    // Every agent stays listed, including the ones that cannot run — disappearing teaches the
    // user nothing. Only the default selection skips them.
    if draft.providerID == nil, let first = agents.first(where: \.isUsable) {
      draft.providerID = first.id.rawValue
    }
    await loadModels()
    if hasSubmitted {
      await revalidate()
    }
  }

  public func loadModels() async {
    guard let providerID = draft.providerID,
      let provider = await registry.provider(id: AgentProviderID(providerID))
    else {
      models = []
      return
    }
    models = await provider.models()
    if let modelID = draft.modelID, !models.contains(where: { $0.id == modelID }) {
      draft.modelID = nil
    }
  }

  public func revalidate() async {
    issues = await create.problems(with: draft)
  }

  /// Returns the created session and the plan to launch, or `nil` when the draft was refused.
  public func submit() async -> SessionCreation? {
    guard !isSubmitting else { return nil }
    hasSubmitted = true
    isSubmitting = true
    defer { isSubmitting = false }

    do {
      let creation = try await create(draft)
      issues = []
      return creation
    } catch let rejection as SessionCreationRejected {
      issues = rejection.issues
      return nil
    } catch {
      issues = [
        SessionDraftIssue(
          field: .name,
          message: (error as? LocalizedError)?.errorDescription
            ?? "The session could not be saved.",
          remedy: "Try again, and report the failure if it persists."
        )
      ]
      return nil
    }
  }
}
