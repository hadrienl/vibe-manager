import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

public struct NewSessionSheet: View {
  /// Bindable, not `@State`: the fields need bindings, but the model belongs to `AppModel` and
  /// must not be frozen at the value this view was first given.
  @Bindable private var model: NewSessionModel
  @FocusState private var focus: SessionDraftField?

  private let defaultWorkingDirectoryPath: String?
  private let created: (SessionCreation) -> Void
  private let cancelled: () -> Void

  public init(
    model: NewSessionModel,
    defaultWorkingDirectoryPath: String? = nil,
    created: @escaping (SessionCreation) -> Void,
    cancelled: @escaping () -> Void
  ) {
    _model = Bindable(model)
    self.defaultWorkingDirectoryPath = defaultWorkingDirectoryPath
    self.created = created
    self.cancelled = cancelled
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      form
      Divider()
      footer
    }
    .frame(width: 700, height: 780)
    .task {
      await model.load(defaultWorkingDirectoryPath: defaultWorkingDirectoryPath)
      focus = .name
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("New Session")
        .font(.title2.weight(.semibold))
      Text("The terminal and the agent start as soon as the session is created.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 14)
  }

  /// The required fields come first, and the cosmetic one last: the folder used to sit below the
  /// fold, which left the sheet refusing to create a session over a field nobody could see.
  private var form: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        nameField
        promptField
        folderField
        slugField
        conventionField
        agentField
        modelField
        appearanceField
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
    }
    .onChange(of: model.draft) {
      model.draftChanged()
    }
  }

  private var nameField: some View {
    LabeledField("Name", issues: model.issues(for: .name)) {
      TextField("What are you working on?", text: $model.draft.name)
        .textFieldStyle(.roundedBorder)
        .focused($focus, equals: .name)
    }
  }

  private var promptField: some View {
    LabeledField(
      "Initial prompt",
      help: "Optional — handed to the agent as its first message.",
      issues: model.issues(for: .initialPrompt)
    ) {
      TextEditor(text: $model.draft.initialPrompt)
        .font(.body)
        .frame(height: 54)
        .overlay {
          RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
        }
        .focused($focus, equals: .initialPrompt)
    }
  }

  private var agentField: some View {
    LabeledField("Agent", issues: model.issues(for: .agent)) {
      VStack(alignment: .leading, spacing: 8) {
        if model.agents.isEmpty {
          Text(
            model.isLoadingAgents
              ? "Looking for coding agents…"
              : "No coding agent was detected on this Mac."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        ForEach(model.agents) { agent in
          AgentRow(
            agent: agent,
            isSelected: agent.id.rawValue == model.draft.providerID,
            select: { Task { await model.select(agent: agent.id.rawValue) } }
          )
        }
        Button("Detect again") {
          Task { await model.refreshAgents(forceRefresh: true) }
        }
        .controlSize(.small)
        .disabled(model.isLoadingAgents)
      }
    }
  }

  @ViewBuilder
  private var modelField: some View {
    LabeledField(
      "Model",
      help: model.models.isEmpty
        ? "This agent published no model list, so it keeps its own default."
        : "Read from the list the CLI caches for itself.",
      issues: model.issues(for: .model)
    ) {
      Picker("Model", selection: $model.draft.modelID) {
        Text("Default model of the agent").tag(String?.none)
        ForEach(model.models) { available in
          Text(available.displayName).tag(String?.some(available.id))
        }
      }
      .labelsHidden()
      .frame(maxWidth: 280, alignment: .leading)
      .disabled(model.models.isEmpty)
    }
  }

  private var appearanceField: some View {
    LabeledField(
      "Appearance",
      help: model.draft.appearance == nil
        ? "Derived from the name until you pick one."
        : nil,
      issues: model.issues(for: .appearance)
    ) {
      HStack(alignment: .top, spacing: 14) {
        SessionBadge(appearance: model.draft.effectiveAppearance, size: 46)

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            ForEach(SessionAppearanceCatalog.symbolNames, id: \.self) { symbol in
              SymbolChoice(
                symbol: symbol,
                isSelected: model.draft.effectiveAppearance.symbolName == symbol,
                select: { pickSymbol(symbol) }
              )
            }
          }
          HStack(spacing: 6) {
            ForEach(SessionAppearanceCatalog.colorHexValues, id: \.self) { hex in
              ColorChoice(
                hex: hex,
                isSelected: model.draft.effectiveAppearance.colorHex == hex,
                select: { pickColor(hex) }
              )
            }
          }
        }
      }
    }
  }

  /// The folders of the session, the main one first, each with what will be done to it.
  private var folderField: some View {
    LabeledField(
      "Repositories",
      help: model.protectedLocationNotice
        ?? "The first one is the main repository: the agent starts in it.",
      issues: model.issues(for: .workingDirectory) + model.issues(for: .repositories)
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if model.draft.repositories.isEmpty {
          Text("No folder yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        ForEach(Array(model.draft.repositories.enumerated()), id: \.element.id) {
          index, repository in
          DraftRepositoryRow(
            repository: repository,
            isMain: index == 0,
            isFirst: index == 0,
            isLast: index == model.draft.repositories.count - 1,
            plan: model.plan(for: repository.id),
            setMode: { model.setMode($0, for: repository.id) },
            setBase: { model.setBase($0, for: repository.id) },
            move: { model.moveRepository(repository.id, by: $0) },
            remove: { model.removeRepository(repository.id) },
            resolve: { resolve($0, for: repository.id) }
          )
        }
        HStack(spacing: 8) {
          Button(model.draft.repositories.isEmpty ? "Choose…" : "Add Repository…") {
            addRepository()
          }
          if model.preview?.additionalDirectoriesUnsupported == true,
            let agent = model.selectedAgent
          {
            Label(
              "\(agent.name) cannot be given the other repositories: only the main one is reachable.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }
      }
    }
  }

  /// The slug, with the branch it becomes. It follows the name until it is typed in — and it is
  /// not shown at all for a session whose folders are all plain or worked in place, which name no
  /// branch.
  @ViewBuilder
  private var slugField: some View {
    if model.preview?.workspace?.usesSessionBranch != false {
      slugEditor
    }
  }

  private var slugEditor: some View {
    LabeledField(
      "Branch",
      help: branchHelp,
      issues: slugIssues
    ) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(SessionSlug.branchPrefix)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
          TextField("slug", text: $model.slugText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($focus, equals: .slug)
          if !model.slugFollowsName {
            Button("Follow the Name") { model.resetSlug() }
              .controlSize(.small)
          }
        }
        if let suggestion = model.preview?.workspace?.slugSuggestion {
          Button("Use \(suggestion.rawValue)") {
            model.slugText = suggestion.rawValue
            model.draftChanged()
          }
          .controlSize(.small)
        }
      }
    }
  }

  /// The slug's own problems, and the collision the plan found, which is shown as soon as it is
  /// known rather than after the first Create — each one once.
  private var slugIssues: [SessionDraftIssue] {
    var seen: Set<SessionDraftIssue.ID> = []
    return (model.issues(for: .slug) + (model.preview?.workspace?.sessionIssues ?? []))
      .filter { seen.insert($0.id).inserted }
  }

  private var branchHelp: String? {
    let fixed = "Fixed once the session exists: renaming the session never renames its branch."
    guard let folder = model.preview?.workspace?.sessionFolderPath,
      model.preview?.workspace?.createsWorktrees == true
    else { return fixed }
    return "Worktrees go in \(abbreviatedPath(folder)). \(fixed)"
  }

  /// What the agent will be told, exactly as it will be sent — folded, and there to be read.
  @ViewBuilder
  private var conventionField: some View {
    if let convention = model.preview?.convention {
      LabeledField("Convention", issues: []) {
        DisclosureGroup("Show what the agent is told first") {
          Text(convention)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .font(.callout)
      }
    }
  }

  private var footer: some View {
    HStack {
      if model.hasSubmitted, !model.issues.isEmpty {
        Label(
          model.issues.count == 1 ? "1 problem to fix" : "\(model.issues.count) problems to fix",
          systemImage: "exclamationmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.red)
      } else {
        Text("Cancel creates nothing — no session, no process.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Cancel", role: .cancel, action: cancelled)
        .keyboardShortcut(.cancelAction)
      Button("Create & Launch", action: submit)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSubmit)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 13)
  }

  /// Only these fields own a control that can take the keyboard: aiming the caret at any other
  /// would leave it nowhere at all.
  private static let focusableFields: Set<SessionDraftField> = [
    .name, .initialPrompt, .slug,
  ]

  private func submit() {
    Task {
      guard let creation = await model.submit() else {
        focus = model.issues.map(\.field).first { Self.focusableFields.contains($0) }
        return
      }
      created(creation)
    }
  }

  private func pickSymbol(_ symbol: String) {
    model.draft.appearance = SessionAppearance(
      symbolName: symbol,
      colorHex: model.draft.effectiveAppearance.colorHex
    )
  }

  private func pickColor(_ hex: String) {
    model.draft.appearance = SessionAppearance(
      symbolName: model.draft.effectiveAppearance.symbolName,
      colorHex: hex
    )
  }

  private func addRepository() {
    let start = model.draft.repositories.last?.resolvedPath.map {
      ($0 as NSString).deletingLastPathComponent
    }
    // The panel opens on the home directory when nothing is chosen yet. The sheet itself
    // proposes no folder — accepting one that contains Desktop, Documents and Downloads would
    // send an agent into them with nothing said — but the panel has to start somewhere.
    guard let path = chooseFolder(startingAt: start) else { return }
    Task {
      if model.draft.repositories.isEmpty {
        await model.folderChosen(path)
      } else {
        await model.addRepository(path)
      }
    }
  }

  private func resolve(_ resolution: RepositoryResolution, for id: RepositoryID) {
    guard model.resolve(resolution, for: id) == .chooseAnotherFolder else { return }
    let current = model.draft.repositories.first { $0.id == id }?.resolvedPath
    guard let path = chooseFolder(startingAt: current) else { return }
    Task {
      if model.draft.repositories.first?.id == id {
        await model.folderChosen(path)
      } else {
        await model.replaceRepository(id, with: path)
      }
    }
  }
}

/// One folder of the draft: its path, how it is attached, and what the plan says about it.
private struct DraftRepositoryRow: View {
  let repository: SessionDraftRepository
  let isMain: Bool
  let isFirst: Bool
  let isLast: Bool
  let plan: RepositoryPlan?
  let setMode: (RepositoryAttachmentMode) -> Void
  let setBase: (RepositoryBase) -> Void
  let move: (Int) -> Void
  let remove: () -> Void
  let resolve: (RepositoryResolution) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: isMain ? "star.circle.fill" : "folder")
          .foregroundStyle(isMain ? Color.accentColor : .secondary)
          .help(isMain ? "Main repository: the agent starts in it." : "")
        VStack(alignment: .leading, spacing: 1) {
          Text(name)
            .fontWeight(.medium)
          Text(abbreviatedPath(repository.resolvedPath ?? repository.path))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        Button {
          move(-1)
        } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(isFirst)
        .accessibilityLabel("Move up")
        Button {
          move(1)
        } label: {
          Image(systemName: "arrow.down")
        }
        .buttonStyle(.borderless)
        .disabled(isLast)
        .accessibilityLabel("Move down")
        Button(action: remove) { Image(systemName: "minus.circle") }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove \(name)")
      }

      if isRepository {
        HStack(spacing: 10) {
          Picker("Mode", selection: modeBinding) {
            Text("Worktree").tag(RepositoryAttachmentMode.worktree)
            Text("In place").tag(RepositoryAttachmentMode.inPlace)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 180)

          if plan?.mode == .worktree {
            Picker("Base", selection: baseBinding) {
              Text("From HEAD").tag(RepositoryBase.head)
              Text("From the default branch").tag(RepositoryBase.defaultBranch)
            }
            .labelsHidden()
            .frame(maxWidth: 220)
          }
        }
      }

      if let plan {
        RepositoryPlanSummary(plan: plan)
        ForEach(plan.issues) { issue in
          RepositoryIssueRow(issue: issue, resolve: resolve)
        }
      } else {
        Text("Read when chosen through the panel.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(9)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          plan?.isBlocked == true ? Color.red.opacity(0.6) : Color(nsColor: .separatorColor))
    )
  }

  private var name: String {
    let component = URL(fileURLWithPath: repository.resolvedPath ?? repository.path)
      .lastPathComponent
    return component.isEmpty ? repository.path : component
  }

  private var isRepository: Bool {
    guard let plan else { return false }
    return plan.mode != .plainFolder && plan.commonDirectory != nil
  }

  private var modeBinding: Binding<RepositoryAttachmentMode> {
    Binding(
      get: { plan?.mode == .inPlace ? .inPlace : .worktree },
      set: { setMode($0) }
    )
  }

  private var baseBinding: Binding<RepositoryBase> {
    Binding(get: { repository.base }, set: { setBase($0) })
  }
}

private struct LabeledField<Content: View>: View {
  private let title: String
  private let help: String?
  private let issues: [SessionDraftIssue]
  private let content: Content

  init(
    _ title: String,
    help: String? = nil,
    issues: [SessionDraftIssue],
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.issues = issues
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 118, alignment: .trailing)

      VStack(alignment: .leading, spacing: 5) {
        content
        ForEach(issues) { issue in
          IssueLabel(issue: issue)
        }
        if let help, issues.isEmpty {
          Text(help)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct IssueLabel: View {
  let issue: SessionDraftIssue

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
      // The remedy sits next to the problem: an error that does not say what to do next is a
      // dead end the user has to guess their way out of.
      Text("\(issue.message) \(issue.remedy)")
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(issue.message) \(issue.remedy)")
  }
}

private struct AgentRow: View {
  let agent: NewSessionModel.AgentOption
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 10) {
        Image(systemName: agent.descriptor.symbolName)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(agent.name)
            .fontWeight(.medium)
          Text(agent.status)
            .font(.caption)
            .foregroundStyle(agent.isUsable ? .secondary : Color.red)
            .fixedSize(horizontal: false, vertical: true)
          if !agent.isUsable {
            // The remedy travels with the diagnostic, here as much as in the validation list.
            Text(agent.remedy)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        if agent.warnsBeforeLaunch {
          Image(systemName: "lock")
            .foregroundStyle(.orange)
            .help("The agent will ask you to sign in inside the terminal.")
        }
        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Unusable agents stay visible and readable, but cannot be chosen.
    .disabled(!agent.isUsable)
    .opacity(agent.isUsable ? 1 : 0.6)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityLabel(
      agent.isUsable
        ? "\(agent.name). \(agent.status)"
        : "\(agent.name). \(agent.status) \(agent.remedy)"
    )
  }
}

private struct SymbolChoice: View {
  let symbol: String
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Image(systemName: symbol)
        .frame(width: 26, height: 26)
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(
              isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
              lineWidth: isSelected ? 2 : 1
            )
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(symbol))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

private struct ColorChoice: View {
  let hex: String
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      RoundedRectangle(cornerRadius: 7)
        .fill(Color(sessionHex: hex))
        .frame(width: 26, height: 26)
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isSelected ? Color.primary : Color.black.opacity(0.15), lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Accent \(hex)"))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
