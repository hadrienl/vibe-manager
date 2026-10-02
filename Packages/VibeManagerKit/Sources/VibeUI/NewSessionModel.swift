import Foundation
import Observation
import VibeApplication
import VibeConversationUI
import VibeDomain

@MainActor
@Observable
public final class NewSessionModel {
  /// Tells drafts apart in a list.
  public var draftID: ObjectIdentifier { ObjectIdentifier(self) }

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
  public var draft = SessionDraft() {
    didSet { commandsFollowDraft() }
  }

  /// The list under a `/` typed first in the initial prompt (#219).
  public let commands = ComposerCommands()
  private let commandCatalog: AgentCommandCatalog
  /// The agent and folder the list is read for.
  private var commandKey: AgentCommandCatalog.Key?
  private var commandConnection: Task<Void, Never>?

  /// The templates offered, in the user's order.
  public private(set) var templates: [PromptTemplate] = []
  /// Whether the template being filled was saved elsewhere since it was picked. The fill keeps
  /// the copy it took, so what is previewed stays what is launched until the user reloads.
  public private(set) var isTemplateStale = false
  /// The name the template made last. The name follows the template as long as it is empty or
  /// still that name: once the user types their own, it is theirs.
  private var generatedName: String?
  /// The agent the form picked by itself: choosing it is not a change the user made.
  private var defaultProviderID: String?
  /// The name `settleName()` gave the draft for sending, taken back if it is refused.
  private var settledName: String?
  /// The folder a template put in the field last, and the one that was there before any did.
  /// Like the name, the folder follows the template until the user picks their own.
  private var presetFolder: String?
  private var folderBeforePreset: String??
  /// The same for the symbol and colour: `nil` in the draft means "derived from the name".
  private var presetAppearance: SessionAppearance?
  private var appearanceBeforePreset: SessionAppearance??
  /// The same for the conversation theme (#274): `nil` in the draft follows the settings.
  private var presetTheme: String?
  private var themeBeforePreset: String??
  /// Whether a theme names one this Mac has: a template's that does not is ignored.
  private let isThemeAvailable: @MainActor (String) -> Bool

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
  /// The load under way, which a second caller joins rather than starts again.
  private var loading: Task<Void, Never>?

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
    forgetRecentFolder: (@MainActor (RecentFolder) -> Void)? = nil,
    /// The symbols and colours the Settings offer (#199), and what a name is given among them.
    palette: SessionAppearancePalette = .default,
    /// The skills and commands read from the agents, shared with the conversations (#219).
    commandCatalog: AgentCommandCatalog = AgentCommandCatalog(),
    /// Whether a conversation theme is there to be given (#274).
    isThemeAvailable: @escaping @MainActor (String) -> Bool = { _ in true }
  ) {
    self.isThemeAvailable = isThemeAvailable
    self.commandCatalog = commandCatalog
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
    draft.palette = palette
  }

  /// The list follows the prompt, and the agent and folder chosen: it is read for them once a `/`
  /// is typed. A folder or agent waits for the field to settle before it is taken, so a path typed
  /// under a prompt that already opens on `/` starts no CLI at each letter.
  private func commandsFollowDraft() {
    commands.update(
      text: draft.initialPrompt, isEnabled: draft.templateFill == nil && !isSubmitting)
    guard let providerID = draft.providerID, !providerID.isEmpty,
      let folder = draft.resolvedWorkingDirectoryPath, folder.hasPrefix("/")
    else {
      if commandKey != nil {
        commandKey = nil
        commandConnection?.cancel()
        commands.read = nil
      }
      return
    }
    let key = AgentCommandCatalog.Key(
      providerID: AgentProviderID(providerID), workingDirectoryPath: folder)
    guard key != commandKey else { return }
    commandKey = key
    commands.read = nil
    commandConnection?.cancel()
    commandConnection = Task { [weak self, registry, commandCatalog, revalidationDelay] in
      try? await Task.sleep(for: revalidationDelay)
      guard !Task.isCancelled else { return }
      guard let listing = await registry.provider(id: key.providerID) as? any AgentCommandListing,
        let self, !Task.isCancelled, self.commandKey == key
      else { return }
      self.commands.read = { await commandCatalog.refreshed(key, from: listing) }
    }
  }

  /// Puts `command` in the prompt in place of what was typed after `/`.
  public func insertCommand(_ command: AgentCommand) {
    draft.initialPrompt = commands.inserting(command)
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

  /// The name is not asked for (#177): left empty, the session is named after its prompt, its
  /// template or its folder. What must be chosen is where the agent works, and which agent.
  public var canSubmit: Bool {
    !isSubmitting && missingRequirement == nil
  }

  /// What still keeps the draft from being sent, said as what to do: the first one only, since the
  /// composer has room for one line. `nil` once everything required is there.
  public var missingRequirement: String? {
    if draft.resolvedWorkingDirectoryPath == nil {
      return String(
        localized: "Choose a working folder to send.", bundle: .module,
        comment: "Next to the Send button of a new session.")
    }
    if draft.providerID?.isEmpty ?? true {
      return String(
        localized: "Choose an agent to send.", bundle: .module,
        comment: "Next to the Send button of a new session.")
    }
    if let field = draft.templateFill?.missingRequiredFields.first {
      return String(
        localized: "Fill in “\(field.label)” to send.", bundle: .module,
        comment: "Next to the Send button of a new session. The label of a template's field.")
    }
    return nil
  }

  /// The name shown where the name is typed, until one is: the one the session would be given.
  public var placeholderName: String {
    let suggested = draft.suggestedName
    return suggested.isEmpty
      ? String(localized: "New Session", bundle: .module, comment: "An unnamed new session.")
      : suggested
  }

  /// Whether the user has changed anything in the draft yet: a draft still pristine is dropped
  /// rather than kept when the user goes elsewhere. The folder and the agent the form proposed
  /// itself are not changes; any other folder, agent, model or appearance is.
  public var isPristine: Bool {
    let folder = draft.workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return draft.trimmedName.isEmpty
      && (folder.isEmpty || draft.workingDirectoryPath == preselectedFolder)
      && (draft.providerID == nil || draft.providerID == defaultProviderID)
      && draft.modelID == nil && draft.appearance == nil && draft.conversationTheme == nil
      && draft.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.attachments.isEmpty
      && draft.templateFill == nil
      && draft.ticketText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The problems of a draft, less the missing name: the name is not asked for (#177), and one is
  /// given at Send. A draft refused for something else must not come back blamed for it too.
  static func namelessAllowed(_ issues: [SessionDraftIssue]) -> [SessionDraftIssue] {
    issues.filter { $0 != .nameMissing }
  }

  /// Gives the draft the name it would be created with, if none was typed. Done at Send, so the
  /// name keeps following the prompt until then.
  public func settleName() {
    guard draft.trimmedName.isEmpty else { return }
    draft.name = draft.suggestedName
    settledName = draft.name
  }

  /// A draft refused comes back unnamed if it was only named for sending: its name follows its
  /// prompt, or its template, again.
  private func unsettleName() {
    if let settledName, draft.name == settledName, settledName != generatedName {
      draft.name = ""
    }
    settledName = nil
  }

  /// Files joined to the prompt (#291): chips under the text, as in a conversation's composer,
  /// in the order they came and each once. Their paths reach the agent with the prompt. A
  /// template's prompt is its own; nothing is joined to it.
  public func attach(_ files: [URL]) {
    guard draft.templateFill == nil else { return }
    for file in files where ShellPath.isWritable(file.path) && !draft.attachments.contains(file) {
      draft.attachments.append(file)
    }
  }

  public func removeAttachment(_ file: URL) {
    draft.attachments.removeAll { $0 == file }
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
    applyThemePreset(of: template)
  }

  /// Whether the conversation theme is the one the template gave.
  public var themeComesFromTemplate: Bool {
    presetTheme != nil && draft.conversationTheme == presetTheme
  }

  /// The theme chosen by the user for the session's conversation; `nil` follows the settings.
  public func chooseConversationTheme(_ theme: String?) {
    draft.conversationTheme = theme
  }

  /// Gives the session the template's conversation theme — one this Mac has —, unless the user
  /// picked their own; a template without any gives back what a previous one replaced.
  private func applyThemePreset(of template: PromptTemplate) {
    let isFree = draft.conversationTheme == nil
    guard isFree || themeComesFromTemplate else { return }
    if let theme = template.conversationTheme, isThemeAvailable(theme) {
      if themeBeforePreset == nil {
        themeBeforePreset = .some(draft.conversationTheme)
      }
      draft.conversationTheme = theme
      presetTheme = theme
    } else if themeComesFromTemplate, let before = themeBeforePreset {
      draft.conversationTheme = before
      presetTheme = nil
      themeBeforePreset = nil
    }
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
    lookForIconOfRecentFolder()
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

  /// Lists the agents and looks at the recent folders. Started by whoever opens the sheet, and
  /// awaited again by the sheet itself, which then places the caret: a call made while a load is
  /// under way joins it.
  ///
  /// It must not hang on the sheet's `.task` alone (#132): in one launch, every sheet opened
  /// without its load ever running — no agent listed, no folder proposed, nothing being looked
  /// for — while its buttons worked, and only Detect Again filled the list.
  public func load() async {
    if let loading {
      await loading.value
      return
    }
    let task = Task { await loadAgentsAndFolders() }
    loading = task
    await task.value
    loading = nil
  }

  private func loadAgentsAndFolders() async {
    // Side by side: the agents need not wait for the folders, nor the folders for the agents.
    async let agents: Void = refreshAgents(forceRefresh: false)
    await checkRecentFolders()
    preselectRecentFolder()
    await agents
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
      defaultProviderID = first.id.rawValue
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
    let found = Self.namelessAllowed(await create.problems(with: checked, checkingFolder: true))
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
    let found = Self.namelessAllowed(
      await create.problems(
        with: checked,
        checkingFolder: path != nil && path == checkedFolderPath
      ))
    // The draft may have moved on while the checks ran, so a verdict on an older one is
    // dropped rather than shown over what the user is looking at now.
    guard !Task.isCancelled, checked == draft else { return }
    issues = found
  }

  /// Whether the draft fails the checks it can answer alone, which are then shown. Those cost
  /// nothing, so they are asked with the sheet still open; the rest waits for `submit()`.
  public func refusesBeforeCreating() async -> Bool {
    guard !isSubmitting else { return true }
    settleName()
    guard !draft.validate().isEmpty else { return false }
    unsettleName()
    revalidation?.cancel()
    revalidation = nil
    hasSubmitted = true
    await revalidate()
    return true
  }

  /// Returns the created session and the plan to launch, or `nil` when the draft was refused.
  public func submit() async -> SessionCreation? {
    guard !isSubmitting else { return nil }
    settleName()
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
    // A theme deleted since it was chosen is not written: the session follows the settings.
    if let theme = draft.conversationTheme, !isThemeAvailable(theme) {
      draft.conversationTheme = nil
    }

    do {
      let creation = try await create(draft)
      issues = []
      return creation
    } catch let rejection as SessionCreationRejected {
      issues = Self.namelessAllowed(rejection.issues)
      unsettleName()
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
      unsettleName()
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

  /// A card clicked: the same gesture as a folder handed back by the open panel, and checked the
  /// same way — except a folder macOS guards, without Full Disk Access. The open panel grants
  /// access to what it hands back; a card does not, so looking at that folder now could raise the
  /// consent alert in the middle of the form. It is checked at creation, like a typed path; only
  /// its icon is read now, which sessions run there have already been allowed to do.
  public func chooseRecentFolder(_ option: RecentFolderOption) async {
    let folder = option.folder
    var mayRead = mayProbe(folder)
    if mayRead, fullDiskAccess != .granted {
      mayRead = await Task.detached {
        RecentFolderProbe.staysOutsideProtectedLocations(folder)
      }.value
    }
    guard mayRead else {
      preselectedFolder = nil
      draft.workingDirectoryPath = option.folder.path
      lookForIconOfRecentFolder()
      return
    }
    await folderChosen(option.folder.path)
  }

  /// Whether this folder may be looked at without a gesture through the system's own panel, as far
  /// as its spellings tell. Its canonical key is asked too: a link to `~/Documents` is inside
  /// `~/Documents`. A key seeded from the spelling alone says nothing of links, so without Full
  /// Disk Access the folder's links are also followed, outside the guarded places, before anything
  /// reads it — see `RecentFolderProbe.staysOutsideProtectedLocations`.
  private func mayProbe(_ folder: RecentFolder) -> Bool {
    fullDiskAccess == .granted
      || (ProtectedFileLocation.covering(path: folder.path) == nil
        && ProtectedFileLocation.covering(path: folder.key) == nil)
  }

  /// Remove from Recents: gone from the sheet now, and from the history kept for the next one.
  public func forget(_ option: RecentFolderOption) {
    recentFolders.removeAll { $0.id == option.id }
    // The sheet's own default goes with its card: left in the field, Create would start the agent
    // in the folder just dismissed, and put it back at the top of the history.
    if let preselected = preselectedFolder, preselected == option.folder.path {
      if draft.workingDirectoryPath == preselected {
        draft.workingDirectoryPath = nil
      }
      if folderBeforePreset == .some(preselected) {
        folderBeforePreset = .some(nil)
      }
      preselectedFolder = nil
    }
    if skippedRecentFolder?.id == option.id {
      skippedRecentFolder = nil
    }
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
    lookForIconOfRecentFolder()
  }

  /// Looks for the icon of the recent folder in the field, even one macOS guards: sessions
  /// already ran there, so the system has already answered for it — the reasoning of New Session
  /// in This Folder. Only its icon is read, never checked as a whole, and only the one folder.
  func lookForIconOfRecentFolder() {
    guard recentFolders.contains(where: { $0.availability != .missing && isSelected($0) })
    else { return }
    lookForIcon()
  }

  /// Looks at each recent folder once, within a budget, without raising a consent alert.
  ///
  /// A folder macOS guards is only looked at when Full Disk Access is known to be granted: a
  /// `stat` inside `~/Documents` is enough to raise the alert ADR 0010 removed from this sheet.
  /// Those, and the ones a slow volume has not answered in time, stay unverified — offered as
  /// they are, and checked at creation like any folder.
  private func checkRecentFolders() async {
    let probed = recentFolders.map(\.folder).filter(mayProbe)
    guard !probed.isEmpty else { return }
    let statuses = await RecentFolderProbe.statuses(
      of: probed, probe: folderProbe, budget: recentFolderProbeBudget,
      followingLinks: fullDiskAccess != .granted)
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
/// on their own while the sheet goes on without them. The budget is kept by a Dispatch timer, not
/// a sleeping task: a cooperative pool busy elsewhere would wake that task late, and hold the sheet
/// for as long as the slowest probe.
enum RecentFolderProbe {
  /// - Parameter followingLinks: whether each folder's links are followed first, and the folder
  ///   left unread when one leads into a place macOS guards.
  static func statuses(
    of folders: [RecentFolder],
    probe: any WorkingDirectoryProbe,
    budget: Duration,
    followingLinks: Bool = false
  ) async -> [String: WorkingDirectoryStatus] {
    guard !folders.isEmpty else { return [:] }
    let collector = Collector(expected: folders.count)
    return await withCheckedContinuation { continuation in
      collector.wait(continuation)
      for folder in folders {
        Task.detached {
          guard !followingLinks || staysOutsideProtectedLocations(folder) else {
            collector.record(nil, for: folder.key)
            return
          }
          let status = await probe.inspect(path: RecentFolder.lexicalKey(of: folder.path))
          collector.record(status, for: folder.key)
        }
      }
      let (seconds, attoseconds) = budget.components
      let delay = Double(seconds) + Double(attoseconds) / 1e18
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
        collector.finish()
      }
    }
  }

  /// Whether the folder's links, followed one component at a time, never lead into a place macOS
  /// guards.
  ///
  /// Only links are read, and only outside those places: `readlink` on `~/code` says where it
  /// points without opening `~/Documents/code`, and a component that is itself guarded is judged
  /// by its path and never read. This is what a key seeded from the spelling alone cannot say.
  static func staysOutsideProtectedLocations(_ folder: RecentFolder) -> Bool {
    var resolved = "/"
    var pending = Array(
      URL(fileURLWithPath: RecentFolder.lexicalKey(of: folder.path)).pathComponents.dropFirst())
    var hops = 0
    while !pending.isEmpty {
      let candidate = (resolved as NSString).appendingPathComponent(pending.removeFirst())
      guard ProtectedFileLocation.covering(path: candidate) == nil else { return false }
      guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)
      else {
        resolved = candidate
        continue
      }
      // A loop of links is not worth untangling: the folder is simply left unread.
      hops += 1
      guard hops <= 32 else { return false }
      let absolute =
        target.hasPrefix("/") ? target : (resolved as NSString).appendingPathComponent(target)
      resolved = "/"
      pending =
        Array(URL(fileURLWithPath: absolute).standardizedFileURL.pathComponents.dropFirst())
        + pending
    }
    return true
  }

  /// Locked rather than an actor: the timer that ends the budget must not wait for the pool.
  private final class Collector: @unchecked Sendable {
    typealias Waiter = CheckedContinuation<[String: WorkingDirectoryStatus], Never>

    private let lock = NSLock()
    private let expected: Int
    private var answered = 0
    private var statuses: [String: WorkingDirectoryStatus] = [:]
    private var isFinished = false
    private var waiter: Waiter?

    init(expected: Int) {
      self.expected = expected
    }

    func wait(_ continuation: Waiter) {
      lock.withLock { waiter = continuation }
    }

    /// `nil`: the folder was left unread, and stays unverified.
    func record(_ status: WorkingDirectoryStatus?, for key: String) {
      let isComplete = lock.withLock {
        guard !isFinished else { return false }
        statuses[key] = status
        answered += 1
        return answered == expected
      }
      if isComplete {
        finish()
      }
    }

    func finish() {
      let answer = lock.withLock { () -> (Waiter, [String: WorkingDirectoryStatus])? in
        guard !isFinished, let waiter else { return nil }
        isFinished = true
        self.waiter = nil
        return (waiter, statuses)
      }
      // Resumed outside the lock: the sheet it wakes may record nothing more, but must not wait.
      if let (waiter, statuses) = answer {
        waiter.resume(returning: statuses)
      }
    }
  }
}
