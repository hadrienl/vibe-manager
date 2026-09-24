import Foundation
import Observation
import VibeApplication
import VibeDomain

@MainActor
@Observable
public final class NewSessionModel {
  /// Shared with the switch of agent: one list, one wording, whichever sheet shows it.
  public typealias AgentOption = VibeUI.AgentOption

  public private(set) var agents: [AgentOption] = []
  public private(set) var models: [AgentModel] = []
  public private(set) var issues: [SessionDraftIssue] = []
  public private(set) var isSubmitting = false
  public private(set) var isLoadingAgents = false
  /// Problems are shown once the user has asked for the session, then kept live: a form that
  /// turns red while the first character is being typed is a form that nags.
  public private(set) var hasSubmitted = false

  /// Edited directly by the sheet's bindings. Reacting to a change is an explicit call rather
  /// than an observer that fires a detached task: the model list the user sees must follow the
  /// agent they just picked, not the scheduler.
  public var draft = SessionDraft()

  private let create: CreateSession
  private let registry: any AgentProviderResolving
  private let revalidationDelay: Duration
  private let fullDiskAccess: FullDiskAccessStatus?
  private var revalidation: Task<Void, Never>?
  /// The folder the open panel last handed over, and the only one checked on the disk before the
  /// user asks for the session.
  private var checkedFolderPath: String?

  /// `fullDiskAccess` decides whether the sheet remarks on a protected folder, and `nil` — not
  /// probed yet — stays silent. The remark is only worth making when the application positively
  /// knows the access is missing; guessing it would warn users who granted it long ago.
  public init(
    create: CreateSession,
    registry: any AgentProviderResolving,
    revalidationDelay: Duration = .milliseconds(250),
    fullDiskAccess: FullDiskAccessStatus? = nil
  ) {
    self.create = create
    self.registry = registry
    self.revalidationDelay = revalidationDelay
    self.fullDiskAccess = fullDiskAccess
  }

  /// What the sheet says under a working folder macOS guards — a remark, never a problem.
  ///
  /// The folder is recognised from its path alone: reading it to find out would raise the very
  /// alert this line exists to announce. It never blocks creation, because being asked once for a
  /// folder the user deliberately chose is a perfectly good outcome.
  public var protectedLocationNotice: String? {
    guard fullDiskAccess == .notGranted,
      let path = draft.resolvedWorkingDirectoryPath,
      let location = ProtectedFileLocation.covering(path: path)
    else {
      return nil
    }
    return """
      macOS protects \(location.label): it may ask for permission the first time the agent reads \
      this folder.
      """
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

    agents = await AgentOption.detect(in: registry, forceRefresh: forceRefresh)

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

  /// Picks an agent and lists that agent's models — the two belong together, so no state exists
  /// where the selected agent and the offered models disagree.
  public func select(agent id: String) async {
    guard draft.providerID != id else { return }
    draft.providerID = id
    draft.modelID = nil
    await loadModels()
    await revalidateIfSubmitted()
  }

  /// Called by the sheet whenever a field changes: problems refresh as they are fixed, but only
  /// once the user has actually asked for the session.
  ///
  /// One task at a time, and only after the typing has paused. A task per keystroke would probe
  /// the disk and the agents on every character, and finish out of order — an early verdict
  /// landing last would post "A name is required." over a name that is now there.
  public func draftChanged() {
    guard hasSubmitted else {
      // Before the first submit the only problems on screen are the ones the open panel came
      // back with, and they judge the folder that was designated then. Once the field says
      // something else they are stale, so they go rather than sit under a path they never saw.
      if draft.workingDirectoryPath != checkedFolderPath {
        checkedFolderPath = nil
        issues = []
      }
      return
    }
    revalidation?.cancel()
    revalidation = Task { [revalidationDelay] in
      try? await Task.sleep(for: revalidationDelay)
      guard !Task.isCancelled else { return }
      await revalidate()
    }
  }

  /// Takes the folder the user just picked in the open panel, and checks that one folder.
  ///
  /// This is the only place outside creation that reads the disk, and it is the right one: the
  /// user has just designated this folder through the system's own panel, so looking at it is
  /// the continuation of their gesture rather than a surprise in the middle of the form.
  public func folderChosen(_ path: String) async {
    revalidation?.cancel()
    revalidation = nil
    // Recorded before the check runs, so the change notification this assignment causes knows
    // the new path is the one being looked at and leaves its verdict alone.
    checkedFolderPath = path
    draft.workingDirectoryPath = path
    let checked = draft
    let found = await create.problems(with: checked, checkingFolder: true)
    guard checkedFolderPath == path else { return }

    // The whole verdict is only published when it still describes the form on screen. A check on
    // a network volume takes long enough for a name to be typed under it, and posting the older
    // answer whole would put "A name is required." back over a name that is now there.
    if hasSubmitted, checked == draft {
      issues = found
      return
    }
    // Otherwise only what was asked about is kept, merged into what is already shown: before the
    // first submit a chosen folder must not turn the whole form red over a name nobody has typed.
    issues =
      issues.filter { $0.field != .workingDirectory }
      + found.filter { $0.field == .workingDirectory }
  }

  public func revalidateIfSubmitted() async {
    guard hasSubmitted else { return }
    await revalidate()
  }

  public func revalidate() async {
    let checked = draft
    // A folder already opened once in this session is opened again: the consent it may have
    // needed has been given, so re-checking it costs nothing and says nothing new to the system.
    // Skipping it instead made a folder that had disappeared vanish from the list of problems as
    // soon as the next field was edited, and come back only at the following Create.
    let path = checked.workingDirectoryPath
    let found = await create.problems(
      with: checked,
      checkingFolder: path != nil && path == checkedFolderPath
    )
    // The draft may have moved on while the checks ran, so a verdict on an older one is
    // dropped rather than shown over what the user is looking at now.
    guard !Task.isCancelled, checked == draft else { return }
    issues = found
  }

  /// Returns the created session and the plan to launch, or `nil` when the draft was refused.
  public func submit() async -> SessionCreation? {
    guard !isSubmitting else { return nil }
    // A pending debounce would otherwise land after the verdict of this submit and replace it.
    revalidation?.cancel()
    revalidation = nil
    hasSubmitted = true
    isSubmitting = true
    defer { isSubmitting = false }
    // Creation opens the folder itself, so from here on it is a folder this session has looked
    // at, and the checks that follow may keep looking at it.
    checkedFolderPath = draft.workingDirectoryPath

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
