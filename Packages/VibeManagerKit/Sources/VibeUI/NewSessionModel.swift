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
    /// Shown next to an agent that cannot run: a diagnostic without a way out is a dead end.
    public var remedy: String { AgentRemediation.sentence(for: remediations) }

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
  /// What was read of each designated folder, kept so the plan can be recomputed on every
  /// keystroke without reading anything again.
  public private(set) var inspections: [RepositoryID: RepositoryInspection] = [:]
  /// The plan, the convention and the command line, as they stand. Shown live, unlike the
  /// problems: seeing what will be created is the point of looking before confirming.
  public private(set) var preview: SessionCreationPreview?

  /// Edited directly by the sheet's bindings. Reacting to a change is an explicit call rather
  /// than an observer that fires a detached task: the model list the user sees must follow the
  /// agent they just picked, not the scheduler.
  public var draft = SessionDraft()

  private let create: CreateSession
  private let registry: any AgentProviderResolving
  private let revalidationDelay: Duration
  private let fullDiskAccess: FullDiskAccessStatus?
  private var revalidation: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
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
      && isPlanShown
  }

  /// With Git, nothing is created before its plan is on screen, for every repository: a folder
  /// still being read would otherwise be prepared without anyone having seen what it would get.
  public var isPlanShown: Bool {
    guard create.plansWorkspace else { return true }
    guard let workspace = preview?.workspace else { return false }
    return draft.repositories.allSatisfy { workspace.plan(for: $0.id) != nil }
  }

  public func issues(for field: SessionDraftField) -> [SessionDraftIssue] {
    issues.filter { $0.field == field }
  }

  public func plan(for id: RepositoryID) -> RepositoryPlan? {
    preview?.workspace?.plan(for: id)
  }

  /// The slug field. Typing in it detaches it from the name for good; clearing it with Reset
  /// makes it follow the name again.
  public var slugText: String {
    get { draft.slugText }
    set { draft.customSlug = newValue }
  }

  public var slugFollowsName: Bool { draft.customSlug == nil }

  public func resetSlug() {
    draft.customSlug = nil
    draftChanged()
  }

  public var branchPreview: String? {
    draft.slug?.branchName
  }

  // MARK: - Repositories

  /// Adds a folder designated through the open panel, and reads it.
  public func addRepository(_ path: String) async {
    let repository = SessionDraftRepository(path: path)
    draft.repositories.append(repository)
    await inspect(repository)
  }

  public func removeRepository(_ id: RepositoryID) {
    draft.repositories.removeAll { $0.id == id }
    inspections[id] = nil
    draftChanged()
  }

  /// The first repository is the main one; moving another to the top makes it the main one.
  public func moveRepository(_ id: RepositoryID, by offset: Int) {
    guard let index = draft.repositories.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard draft.repositories.indices.contains(target) else { return }
    draft.repositories.swapAt(index, target)
    draftChanged()
  }

  public func setMode(_ mode: RepositoryAttachmentMode, for id: RepositoryID) {
    update(id) {
      $0.mode = mode
      $0.choice = nil
    }
  }

  public func setBase(_ base: RepositoryBase, for id: RepositoryID) {
    update(id) { $0.base = base }
  }

  /// Carries out the resolution the user picked, or returns what the sheet must do for it.
  @discardableResult
  func resolve(_ resolution: RepositoryResolution, for id: RepositoryID)
    -> RepositoryResolutionEffect
  {
    guard let index = draft.repositories.firstIndex(where: { $0.id == id }) else {
      return .applied
    }
    var repository = draft.repositories[index]
    let effect = repository.apply(resolution)
    switch effect {
    case .applied:
      draft.repositories[index] = repository
      draftChanged()
    case .remove:
      removeRepository(id)
    case .changeSlug(let suggestion):
      draft.customSlug = suggestion
      draftChanged()
    case .chooseAnotherFolder:
      break
    }
    return effect
  }

  /// Replaces one repository's folder with another designated through the panel.
  public func replaceRepository(_ id: RepositoryID, with path: String) async {
    guard let index = draft.repositories.firstIndex(where: { $0.id == id }) else { return }
    let repository = SessionDraftRepository(id: id, path: path)
    draft.repositories[index] = repository
    inspections[id] = nil
    await inspect(repository)
  }

  private func update(_ id: RepositoryID, _ change: (inout SessionDraftRepository) -> Void) {
    guard let index = draft.repositories.firstIndex(where: { $0.id == id }) else { return }
    change(&draft.repositories[index])
    draftChanged()
  }

  private func inspect(_ repository: SessionDraftRepository) async {
    // Without Git there is nothing to plan: the folder is checked by the problems, as it always
    // was, and reading it a second time here would only open it twice.
    guard create.plansWorkspace else { return }
    let inspection = await create.inspect(repository)
    guard
      draft.repositories.contains(where: { $0.id == repository.id && $0.path == repository.path })
    else { return }
    inspections[repository.id] = inspection
    await refreshPreview()
  }

  /// Recomputes the plan from what was already read. Reads no folder.
  public func refreshPreview() async {
    guard create.plansWorkspace else { return }
    let checked = draft
    let read = inspections
    let found = await create.preview(checked, inspections: read)
    // Dropped unless it still describes the form *and* what was read: a preview scheduled before
    // a folder was read would otherwise land last and take its plan off the screen.
    guard !Task.isCancelled, checked == draft, read == inspections else { return }
    preview = found
  }

  private func schedulePreview() {
    guard create.plansWorkspace else { return }
    previewTask?.cancel()
    previewTask = Task { [revalidationDelay] in
      try? await Task.sleep(for: revalidationDelay)
      guard !Task.isCancelled else { return }
      await refreshPreview()
    }
  }

  public func load(defaultWorkingDirectoryPath: String?) async {
    if draft.workingDirectoryPath == nil {
      draft.workingDirectoryPath = defaultWorkingDirectoryPath
    }
    await refreshAgents(forceRefresh: false)
    await refreshPreview()
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
    defer { schedulePreview() }
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
    schedulePreview()
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
    if let main = draft.repositories.first {
      inspections[main.id] = nil
      await inspect(main)
    }
    let checked = draft
    let found = await create.problems(
      with: checked, checkingFolder: true, inspections: inspections)
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
      checkingFolder: path != nil && path == checkedFolderPath,
      inspections: inspections
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
      let creation = try await create(draft, expecting: preview?.workspace)
      issues = []
      return creation
    } catch let rejection as SessionCreationRejected {
      issues = rejection.issues
      if rejection.issues.contains(.planChanged) {
        // What was read no longer holds: every folder is read again, and the new plan shown.
        inspections = [:]
        for repository in draft.repositories {
          await inspect(repository)
        }
      }
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
