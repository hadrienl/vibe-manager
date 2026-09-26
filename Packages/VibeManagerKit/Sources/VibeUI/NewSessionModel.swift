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

  /// The templates offered, in the user's order.
  public private(set) var templates: [PromptTemplate] = []
  /// Whether the template being filled was saved elsewhere since it was picked. The fill keeps
  /// the copy it took, so what is previewed stays what is launched until the user reloads.
  public private(set) var isTemplateStale = false
  /// The name the template made last. The name follows the template as long as it is empty or
  /// still that name: once the user types their own, it is theirs.
  private var generatedName: String?
  /// The folder a template put in the field last, and the one that was there before any did.
  /// Like the name, the folder follows the template until the user picks their own.
  private var presetFolder: String?
  private var folderBeforePreset: String??
  /// The same for the symbol and colour: `nil` in the draft means "derived from the name".
  private var presetAppearance: SessionAppearance?
  private var appearanceBeforePreset: SessionAppearance??

  /// The folders sessions were created in, the most recent first, as the sheet offers them (#39).
  public private(set) var recentFolders: [RecentFolderOption]
  /// Whether the cards past the first three are shown. For the life of the sheet only.
  public var isShowingMoreFolders = false
  /// The recent folder the sheet put in the field itself. Like a template's folder it is a
  /// default, not a choice: a template replaces it, and leaving the template gives it back.
  public private(set) var preselectedFolder: String?
  /// The folder that would have been preselected had it still been there.
  private var skippedRecentFolder: RecentFolderOption?
  private let folderProbe: any WorkingDirectoryProbe
  private let recentFolderProbeBudget: Duration
  private let forgetRecentFolder: (@MainActor (RecentFolder) -> Void)?

  private let create: CreateSession
  private let registry: any AgentProviderResolving
  private let revalidationDelay: Duration
  private let fullDiskAccess: FullDiskAccessStatus?
  private var revalidation: Task<Void, Never>?
  /// The folder the open panel last handed over, and the only one checked on the disk before the
  /// user asks for the session.
  private var checkedFolderPath: String?
  private let projectIcons: any ProjectIconFinding
  let icons: SessionIconLibrary?
  /// The folder the project icon was last looked for in, and the search under way.
  private var iconFolderPath: String?
  private var iconSearch: Task<Void, Never>?

  /// `fullDiskAccess` decides whether the sheet remarks on a protected folder, and `nil` — not
  /// probed yet — stays silent. The remark is only worth making when the application positively
  /// knows the access is missing; guessing it would warn users who granted it long ago.
  public init(
    create: CreateSession,
    registry: any AgentProviderResolving,
    revalidationDelay: Duration = .milliseconds(250),
    fullDiskAccess: FullDiskAccessStatus? = nil,
    templates: [PromptTemplate] = [],
    projectIcons: any ProjectIconFinding = NoProjectIcons(),
    icons: SessionIconLibrary? = nil,
    recentFolders: [RecentFolder] = [],
    folderProbe: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    recentFolderProbeBudget: Duration = .milliseconds(300),
    forgetRecentFolder: (@MainActor (RecentFolder) -> Void)? = nil
  ) {
    self.projectIcons = projectIcons
    self.icons = icons
    self.templates = templates
    self.recentFolders = RecentFolderOption.options(for: recentFolders)
    self.folderProbe = folderProbe
    self.recentFolderProbeBudget = recentFolderProbeBudget
    self.forgetRecentFolder = forgetRecentFolder
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
    return String(
      localized: """
        macOS protects \(location.label): it may ask for permission the first time the agent \
        reads this folder.
        """,
      bundle: .module,
      comment: "A protected place: “your Desktop”, “your Documents folder”, “iCloud Drive”.")
  }

  public var selectedAgent: AgentOption? {
    guard let providerID = draft.providerID else { return nil }
    return agents.first { $0.id.rawValue == providerID }
  }

  public var canSubmit: Bool {
    !isSubmitting && !draft.trimmedName.isEmpty && draft.resolvedWorkingDirectoryPath != nil
      && (draft.templateFill?.missingRequiredFields.isEmpty ?? true)
  }

  // MARK: - Templates

  public var selectedTemplateID: PromptTemplateID? {
    draft.templateFill?.template.id
  }

  /// The prompt as it will be sent, part by part, when a template is filled in.
  public var renderedPrompt: RenderedPrompt? {
    draft.templateFill?.render()
  }

  public func issues(forTemplateField key: String) -> [SessionDraftIssue] {
    issues.filter { $0.field == .templateField && $0.fieldKey == key }
  }

  /// Picks a template, or goes back to a free prompt with `nil`.
  ///
  /// Nothing on screen is lost either way: values of fields sharing a name carry over to the next
  /// template, and leaving the templates turns what was rendered into the free prompt.
  public func selectTemplate(_ id: PromptTemplateID?) {
    guard id != selectedTemplateID else { return }
    guard let id, let template = templates.first(where: { $0.id == id }) else {
      editAsText()
      return
    }
    let previous = draft.templateFill?.values ?? [:]
    let keys = Set(template.fields.map(\.name))
    draft.templateFill = PromptTemplateFill(
      template: template, values: previous.filter { keys.contains($0.key) })
    isTemplateStale = false
    refreshName()
    applyFolderPreset(of: template)
    applyAppearancePreset(of: template)
  }

  /// Whether the symbol and colour are the ones the template gave.
  public var appearanceComesFromTemplate: Bool {
    presetAppearance != nil && draft.appearance == presetAppearance
  }

  /// Gives the session the template's symbol and colour, unless the user picked their own; a
  /// template without any gives back what a previous one replaced.
  private func applyAppearancePreset(of template: PromptTemplate) {
    let isFree = draft.appearance == nil
    guard isFree || appearanceComesFromTemplate else { return }
    if let appearance = template.appearance {
      if appearanceBeforePreset == nil {
        appearanceBeforePreset = .some(draft.appearance)
      }
      draft.appearance = appearance
      presetAppearance = appearance
    } else if appearanceComesFromTemplate, let before = appearanceBeforePreset {
      draft.appearance = before
      presetAppearance = nil
      appearanceBeforePreset = nil
    }
  }

  /// Whether the folder in the field is the one the template proposed.
  public var folderComesFromTemplate: Bool {
    presetFolder != nil && draft.workingDirectoryPath == presetFolder
  }

  /// Puts the template's folder in the field — unless the user chose one of their own — and,
  /// for a template that proposes none, gives back the folder a previous template replaced.
  private func applyFolderPreset(of template: PromptTemplate) {
    let current = draft.workingDirectoryPath
    let isEmpty = current?.isEmpty ?? true
    // A folder the sheet preselected is as free as an empty field: the user never chose it.
    let isFree = isEmpty || (preselectedFolder != nil && current == preselectedFolder)
    guard isFree || folderComesFromTemplate else { return }
    if let folder = template.folder {
      if folderBeforePreset == nil {
        folderBeforePreset = .some(isEmpty ? nil : current)
      }
      draft.workingDirectoryPath = folder
      presetFolder = folder
    } else if folderComesFromTemplate, let before = folderBeforePreset {
      draft.workingDirectoryPath = before
      presetFolder = nil
      folderBeforePreset = nil
    }
  }

  public func setValue(_ value: String, for key: String) {
    draft.templateFill?.setValue(value, for: key)
    refreshName()
  }

  public func value(for key: String) -> String {
    draft.templateFill?.value(for: key) ?? ""
  }

  /// The rendered prompt becomes free text to edit by hand, and the template reference goes: it
  /// promised this prompt was that template filled in, which is no longer true.
  public func editAsText() {
    guard let fill = draft.templateFill else { return }
    draft.initialPrompt = fill.render().editableText
    draft.templateFill = nil
    isTemplateStale = false
    generatedName = nil
  }

  /// The templates as the library now holds them.
  public func templatesChanged(_ library: [PromptTemplate]) {
    templates = library
    guard let fill = draft.templateFill else { return }
    let current = library.first { $0.id == fill.template.id }
    isTemplateStale = current.map { !$0.hasSameContent(as: fill.template) } ?? false
  }

  /// Takes the template as it now is, keeping the values of the fields it still has.
  public func reloadTemplate() {
    guard let fill = draft.templateFill,
      let current = templates.first(where: { $0.id == fill.template.id })
    else {
      isTemplateStale = false
      return
    }
    let keys = Set(current.fields.map(\.name))
    draft.templateFill = PromptTemplateFill(
      template: current, values: fill.values.filter { keys.contains($0.key) })
    isTemplateStale = false
    refreshName()
  }

  private func refreshName() {
    guard let name = draft.templateFill?.sessionName() else { return }
    guard draft.name.isEmpty || draft.name == generatedName else { return }
    draft.name = name
    generatedName = name
  }

  public func issues(for field: SessionDraftField) -> [SessionDraftIssue] {
    issues.filter { $0.field == field }
  }

  public func load() async {
    await checkRecentFolders()
    preselectRecentFolder()
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
    // An icon found in another folder is not this one's; coming back to that folder looks again.
    if iconFolderPath != nil, draft.resolvedWorkingDirectoryPath != iconFolderPath {
      iconSearch?.cancel()
      iconFolderPath = nil
      if draft.projectIcon != nil { draft.projectIcon = nil }
    }
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
    // Designated by the user now: no longer a default a template may replace.
    preselectedFolder = nil
    draft.workingDirectoryPath = path
    lookForIcon()
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

  // MARK: - Project icon

  /// Whether the badge shows the icon found in the folder, because nothing else was chosen.
  public var usesProjectIcon: Bool {
    draft.usesProjectIcon
  }

  /// Goes back to the project's icon after picking a symbol or a colour.
  public func useProjectIcon() {
    guard draft.projectIcon != nil else { return }
    draft.appearance = nil
  }

  /// Looks for the icon of the folder in the field, and drops the one of the previous folder.
  ///
  /// Only for a folder the user designated — through the open panel, or at creation — never while
  /// a path is typed: reading a folder macOS guards raises the system's consent alert, and that
  /// must follow a gesture. The answer is only kept if the field still names that folder.
  func lookForIcon() {
    let path = draft.resolvedWorkingDirectoryPath
    guard path != iconFolderPath else { return }
    iconSearch?.cancel()
    iconFolderPath = path
    draft.projectIcon = nil
    guard let path else { return }
    iconSearch = Task { [projectIcons] in
      let icon = await projectIcons.icon(inFolder: path)
      guard !Task.isCancelled, self.iconFolderPath == path,
        self.draft.resolvedWorkingDirectoryPath == path
      else { return }
      if let icon { self.icons?.insert(icon) }
      self.draft.projectIcon = icon
    }
  }

  /// The icon of the folder in the field, looked for now if it has not been: creation opens the
  /// folder anyway, and the session is owed the same default whether the folder was typed or
  /// picked.
  private func settleIcon() async {
    lookForIcon()
    await iconSearch?.value
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
    await settleIcon()

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
            ?? String(localized: "The session could not be saved.", bundle: .module),
          remedy: String(
            localized: "Try again, and report the failure if it persists.", bundle: .module)
        )
      ]
      return nil
    }
  }
}

// MARK: - Recent folders

extension NewSessionModel {
  /// How many recent folders are shown before Show More.
  public static let visibleRecentFolderCount = 3

  /// The cards on screen: the first three, or all of them once Show More was pressed.
  public var shownRecentFolders: [RecentFolderOption] {
    isShowingMoreFolders
      ? recentFolders : Array(recentFolders.prefix(Self.visibleRecentFolderCount))
  }

  /// How many folders Show More would add. Zero: the card is not offered at all.
  public var hiddenRecentFolderCount: Int {
    max(recentFolders.count - Self.visibleRecentFolderCount, 0)
  }

  /// Whether the field names this folder. Compared by spelling: drawing a card never reads the
  /// disk, and typing the path of a recent folder lights its card as much as clicking it.
  public func isSelected(_ option: RecentFolderOption) -> Bool {
    guard let path = draft.resolvedWorkingDirectoryPath else { return false }
    return RecentFolder.lexicalKey(of: path) == RecentFolder.lexicalKey(of: option.folder.path)
  }

  /// A card clicked: the same gesture as a folder handed back by the open panel.
  public func chooseRecentFolder(_ option: RecentFolderOption) async {
    await folderChosen(option.folder.path)
  }

  /// Remove from Recents: gone from the sheet now, and from the history kept for the next one.
  public func forget(_ option: RecentFolderOption) {
    recentFolders.removeAll { $0.id == option.id }
    if hiddenRecentFolderCount == 0 {
      isShowingMoreFolders = false
    }
    forgetRecentFolder?(option.folder)
  }

  /// Said under the field when the last folder has gone and the next one was proposed in its
  /// place: an agent must not start in another repository without the user seeing it.
  public var preselectionNotice: String? {
    guard let skipped = skippedRecentFolder, let preselectedFolder,
      draft.workingDirectoryPath == preselectedFolder
    else {
      return nil
    }
    return String(
      localized: "“\(skipped.name)” was not found — the next recent folder is proposed.",
      bundle: .module,
      comment: "Under the working folder: the last folder used has gone. The name of that folder.")
  }

  /// Puts the most recent folder still there in an empty field. A template that brought its own
  /// folder already filled it, and wins.
  private func preselectRecentFolder() {
    guard draft.workingDirectoryPath?.isEmpty ?? true,
      let index = recentFolders.firstIndex(where: { $0.availability != .missing })
    else {
      return
    }
    let option = recentFolders[index]
    skippedRecentFolder = index > 0 ? recentFolders[0] : nil
    preselectedFolder = option.folder.path
    draft.workingDirectoryPath = option.folder.path
  }

  /// Looks at each recent folder once, within a budget, without raising a consent alert.
  ///
  /// A folder macOS guards is only looked at when Full Disk Access is known to be granted: a
  /// `stat` inside `~/Documents` is enough to raise the alert ADR 0010 removed from this sheet.
  /// Those, and the ones a slow volume has not answered in time, stay unverified — offered as
  /// they are, and checked at creation like any folder.
  private func checkRecentFolders() async {
    let probed = recentFolders.map(\.folder).filter { folder in
      fullDiskAccess == .granted || ProtectedFileLocation.covering(path: folder.path) == nil
    }
    guard !probed.isEmpty else { return }
    let statuses = await RecentFolderProbe.statuses(
      of: probed, probe: folderProbe, budget: recentFolderProbeBudget)
    recentFolders = recentFolders.map { option in
      guard let status = statuses[option.id] else { return option }
      return option.with(RecentFolderOption.Availability(status))
    }
  }
}

/// One recent folder as the sheet offers it.
public struct RecentFolderOption: Identifiable, Equatable, Sendable {
  public enum Availability: Equatable, Sendable {
    case available
    /// Not looked at: guarded by macOS, or too slow to answer. Offered, and checked at creation.
    case unverified
    /// Deleted or moved. Shown so a volume unplugged for now keeps its place, never preselected.
    case missing

    init(_ status: WorkingDirectoryStatus) {
      switch status {
      case .usable: self = .available
      case .missing, .notADirectory: self = .missing
      // It is there. What is wrong with it is said at creation, with its remedy.
      case .unreadable: self = .unverified
      }
    }
  }

  public let folder: RecentFolder
  /// The folder's name, told apart from a namesake by its parent: `api — client-a`.
  public let name: String
  /// Where it is: the enclosing folder, as `~/…`.
  public let location: String
  public let availability: Availability

  public var id: String { folder.key }
  /// The full path as `~/…`, for the help tag and VoiceOver.
  public var displayPath: String {
    (RecentFolder.lexicalKey(of: folder.path) as NSString).abbreviatingWithTildeInPath
  }

  func with(_ availability: Availability) -> RecentFolderOption {
    RecentFolderOption(folder: folder, name: name, location: location, availability: availability)
  }

  static func options(for folders: [RecentFolder]) -> [RecentFolderOption] {
    let names = RecentFolderNames.displayNames(for: folders.map(\.path))
    return zip(folders, names).map { folder, name in
      let parent = (RecentFolder.lexicalKey(of: folder.path) as NSString).deletingLastPathComponent
      return RecentFolderOption(
        folder: folder, name: name,
        location: (parent as NSString).abbreviatingWithTildeInPath,
        availability: .unverified)
    }
  }
}

/// Probes folders side by side and answers once all have, or once the budget is spent.
///
/// A probe cannot be interrupted — `stat` on a network volume that went away takes as long as it
/// takes — so they run detached, and the ones still out when the budget ends are left to finish
/// on their own while the sheet goes on without them.
enum RecentFolderProbe {
  static func statuses(
    of folders: [RecentFolder],
    probe: any WorkingDirectoryProbe,
    budget: Duration
  ) async -> [String: WorkingDirectoryStatus] {
    let collector = Collector(expected: folders.count)
    for folder in folders {
      Task.detached {
        let status = await probe.inspect(path: RecentFolder.lexicalKey(of: folder.path))
        await collector.record(status, for: folder.key)
      }
    }
    Task.detached {
      try? await Task.sleep(for: budget)
      await collector.finish()
    }
    return await collector.results()
  }

  private actor Collector {
    private let expected: Int
    private var statuses: [String: WorkingDirectoryStatus] = [:]
    private var isFinished = false
    private var waiter: CheckedContinuation<[String: WorkingDirectoryStatus], Never>?

    init(expected: Int) {
      self.expected = expected
    }

    func record(_ status: WorkingDirectoryStatus, for key: String) {
      guard !isFinished else { return }
      statuses[key] = status
      if statuses.count == expected {
        finish()
      }
    }

    func finish() {
      guard !isFinished else { return }
      isFinished = true
      waiter?.resume(returning: statuses)
      waiter = nil
    }

    func results() async -> [String: WorkingDirectoryStatus] {
      if isFinished { return statuses }
      return await withCheckedContinuation { waiter = $0 }
    }
  }
}
