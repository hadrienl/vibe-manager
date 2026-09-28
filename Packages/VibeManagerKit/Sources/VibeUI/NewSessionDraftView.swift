import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// A new session, before it exists (#177): a conversation not started yet, in the main area.
///
/// The options come first, as a card at the head of the thread — the template, which may propose
/// the rest, then where the agent works and which agent — and the composer at the foot is the
/// initial prompt. Sending creates the session and launches it; nothing is stored and nothing runs
/// before. Send stays unavailable, and says why, until what is required is there.
public struct NewSessionDraftView: View {
  /// Bindable, not `@State`: the fields need bindings, but the model belongs to `AppModel` and
  /// must not be frozen at the value this view was first given.
  @Bindable private var model: NewSessionModel
  @FocusState private var focus: FocusTarget?
  /// The prompt areas are AppKit text views, which SwiftUI's focus does not reach: where the caret
  /// was sent is kept here too, and they take it themselves.
  @State private var editorRequest: FocusTarget?
  /// The ticket and the appearance, folded away until asked for — or until one of them has
  /// something to say.
  @State private var showsMoreOptions = false

  /// What can hold the keyboard: the draft's own fields, and the ones a template adds.
  enum FocusTarget: Hashable {
    case draft(SessionDraftField)
    case templateField(String)
  }

  /// Bumped each time the draft is brought on screen: the caret goes back to the composer.
  private let focusRequest: Int
  /// Send was pressed on a draft that passes its own checks: whether to launch the session now
  /// or leave it in To Do (#80). The rest — the folder, the agent, the store — is checked with the
  /// draft gone, and a refusal brings it back.
  private let submitted: (Bool) -> Void
  /// Escape: the draft is set aside, or dropped when nothing of the user's is in it.
  private let dismissed: () -> Void
  /// Discard: the draft goes, whatever is in it.
  private let discarded: () -> Void
  /// Opens the panel to choose files to join to the prompt.
  private let chooseFiles: () -> Void
  /// Opens the templates in the settings. `nil`: the draft offers no way there.
  private let manageTemplates: (() -> Void)?

  public init(
    model: NewSessionModel,
    focusRequest: Int = 0,
    submitted: @escaping (Bool) -> Void,
    dismissed: @escaping () -> Void,
    discarded: @escaping () -> Void,
    chooseFiles: @escaping () -> Void,
    manageTemplates: (() -> Void)? = nil
  ) {
    _model = Bindable(model)
    self.focusRequest = focusRequest
    self.submitted = submitted
    self.dismissed = dismissed
    self.discarded = discarded
    self.chooseFiles = chooseFiles
    self.manageTemplates = manageTemplates
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        optionsCard
          .frame(maxWidth: 760)
          .padding(.horizontal, 24)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity)
      }
      composer
        .frame(maxWidth: 800)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }
    .background(.background)
    .onChange(of: model.draft) {
      model.draftChanged()
    }
    .onChange(of: model.issues) {
      if !model.issues(for: .appearance).isEmpty { showsMoreOptions = true }
    }
    .onChange(of: focusRequest) {
      placeCaret()
    }
    .task {
      showsMoreOptions =
        !model.draft.ticketText.isEmpty || !model.issues(for: .appearance).isEmpty
      await model.load()
      placeCaret()
    }
    // A file dropped anywhere on the draft joins its prompt, as the composer of a conversation
    // takes one.
    .dropDestination(for: URL.self) { urls, _ in
      guard model.draft.templateFill == nil else { return false }
      model.attach(urls.filter(\.isFileURL))
      return true
    }
    .background {
      // Escape sets the draft aside. A button rather than a key handler: the prompt is an AppKit
      // text view, which keeps Escape for itself otherwise.
      Button(action: dismissed) {
        Text("Set Aside", bundle: .module, comment: "Escape in a new session's draft.")
      }
      .keyboardShortcut(.cancelAction)
      .hidden()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("New Session", bundle: .module, comment: "An unnamed new session."))
    .accessibilityIdentifier("new-session-draft")
  }

  // MARK: - Header

  /// The name, typed where a session shows its name. Left empty, it shows the one the session will
  /// be given.
  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        SessionBadge(
          appearance: model.draft.effectiveAppearance,
          icon: model.icons?.image(for: model.draft.effectiveAppearance.iconID), size: 26)
        TextField(
          text: $model.draft.name,
          prompt: Text(verbatim: model.placeholderName)
        ) {
          Text("Name", bundle: .module, comment: "The name of the new session.")
        }
        .textFieldStyle(.plain)
        .font(.title3.weight(.semibold))
        .focused($focus, equals: .draft(.name))
        .accessibilityIdentifier("new-session-name")
        Spacer(minLength: 12)
        Text("Nothing starts before you send.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Button(role: .destructive, action: discarded) {
          Text("Discard", bundle: .module, comment: "Discards the new session's draft.")
        }
        .controlSize(.small)
        .help(Text("Discard this draft. No session is created.", bundle: .module))
        .accessibilityIdentifier("new-session-discard")
      }
      ForEach(model.issues(for: .name)) { issue in
        IssueLabel(issue: issue)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Options

  /// The options, as the first message of the thread.
  private var optionsCard: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Where, and with which agent?", bundle: .module)
            .font(.headline)
          Text("What you write below is the agent’s first message.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // The template first, and its fields with it: it may propose the folder, the name and the
        // appearance, and what it needs filled in is what Send waits for.
        templateField
        templateFields
        Divider()
        folderField
        agentField
        modelField
        moreOptions
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14).strokeBorder(.separator)
      }
    }
  }

  private var moreOptions: some View {
    DisclosureGroup(isExpanded: $showsMoreOptions) {
      VStack(alignment: .leading, spacing: 14) {
        ticketField
        appearanceField
      }
      .padding(.top, 10)
    } label: {
      HStack(spacing: 6) {
        Text("More Options", bundle: .module, comment: "Unfolds the ticket and the appearance.")
        Text("Ticket, appearance", bundle: .module, comment: "What More Options unfolds.")
          .foregroundStyle(.secondary)
      }
      .font(.callout)
    }
    .accessibilityIdentifier("new-session-more-options")
  }

  @ViewBuilder
  private var templateField: some View {
    LabeledField(
      Text("Prompt template", bundle: .module, comment: "The template the session starts from."),
      help: model.templates.isEmpty
        ? Text(
          "No templates yet — Manage… to write one, or add the examples.", bundle: .module,
          comment: "Manage… is the button next to the template picker.")
        : Text("A template can propose the folder, the name and the appearance.", bundle: .module),
      issues: []
    ) {
      HStack(spacing: 8) {
        Picker(
          selection: Binding(
            get: { model.selectedTemplateID },
            set: { id in
              model.selectTemplate(id)
              if let fill = model.draft.templateFill {
                moveFocus(to: firstEmptyField(in: fill))
              } else {
                moveFocus(to: .draft(.initialPrompt))
              }
            }
          )
        ) {
          Text("None — free prompt", bundle: .module, comment: "No prompt template.")
            .tag(PromptTemplateID?.none)
          if !model.templates.isEmpty {
            Divider()
          }
          ForEach(model.templates) { template in
            Label {
              Text(template.trimmedName)
            } icon: {
              Image(systemName: template.appearance?.symbolName ?? "text.badge.plus")
            }
            .tag(PromptTemplateID?.some(template.id))
          }
        } label: {
          Text("Prompt template", bundle: .module, comment: "The template the session starts from.")
        }
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)

        if let manageTemplates {
          Button(action: manageTemplates) {
            Text("Manage…", bundle: .module, comment: "Opens the prompt templates window.")
          }
          .controlSize(.small)
        }
      }
    }
    if model.isTemplateStale {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary)
        Text("This template changed since you picked it.", bundle: .module)
          .font(.caption)
        Button {
          model.reloadTemplate()
        } label: {
          Text("Reload", bundle: .module, comment: "Reloads the changed template into the form.")
        }
        .controlSize(.small)
      }
      .padding(.leading, LabeledField<EmptyView>.titleWidth + 12)
      .accessibilityElement(children: .combine)
    }
  }

  /// One control per field of the template, in the order the text reads them.
  @ViewBuilder
  private var templateFields: some View {
    if let fill = model.draft.templateFill {
      ForEach(fill.template.fields) { field in
        LabeledField(
          Text(verbatim: field.label),
          requirement: field.isRequired
            ? (model.value(for: field.name).trimmingCharacters(in: .whitespacesAndNewlines)
              .isEmpty ? .missing : .met) : nil,
          issues: model.issues(forTemplateField: field.name)
        ) {
          let text = Binding(
            get: { model.value(for: field.name) },
            set: { model.setValue($0, for: field.name) }
          )
          Group {
            if field.isMultiline {
              PromptTextEditor(
                text: text,
                minimumLines: 2,
                placeholder: field.help,
                accessibilityLabel: field.label,
                focusRequested: editorRequest == .templateField(field.name)
              )
            } else {
              TextField(field.help ?? "", text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(field.label)
            }
          }
          .focused($focus, equals: .templateField(field.name))
          .accessibilityValue(
            field.isRequired
              ? Text(
                "Required", bundle: .module, comment: "VoiceOver: a field that must be filled.")
              : Text(verbatim: ""))
          // What the patterns of the template keep of the value, once there is one.
          if !model.value(for: field.name).isEmpty {
            ExtractionResultsView(results: fill.extractions(for: field.name))
          }
        }
      }
    }
  }

  private var agentField: some View {
    LabeledField(
      Text("Agent", bundle: .module, comment: "The coding agent the session runs."),
      requirement: model.selectedAgent?.isUsable == true ? .met : .missing,
      issues: model.issues(for: .agent)
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if model.agents.isEmpty {
          Group {
            if model.isLoadingAgents {
              Text("Looking for coding agents…", bundle: .module)
            } else {
              Text("No coding agent was detected on this Mac.", bundle: .module)
            }
          }
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        ForEach(model.agents) { agent in
          AgentChoiceRow(
            agent: agent,
            isSelected: agent.id.rawValue == model.draft.providerID,
            select: { Task { await model.select(agent: agent.id.rawValue) } }
          )
        }
        Button {
          Task { await model.refreshAgents(forceRefresh: true) }
        } label: {
          Text("Detect again", bundle: .module)
        }
        .controlSize(.small)
        .disabled(model.isLoadingAgents)
      }
    }
  }

  @ViewBuilder
  private var modelField: some View {
    LabeledField(
      Text("Model", bundle: .module, comment: "The model of a coding agent."),
      help: model.models.isEmpty
        ? Text("This agent published no model list, so it keeps its own default.", bundle: .module)
        : Text("Read from the list the CLI caches for itself.", bundle: .module),
      issues: model.issues(for: .model)
    ) {
      Picker(selection: $model.draft.modelID) {
        Text("Default model of the agent", bundle: .module).tag(String?.none)
        ForEach(model.models) { available in
          Text(available.displayName).tag(String?.some(available.id))
        }
      } label: {
        Text("Model", bundle: .module, comment: "The model of a coding agent.")
      }
      .labelsHidden()
      .frame(maxWidth: 280, alignment: .leading)
      .disabled(model.models.isEmpty)
    }
  }

  private var appearanceField: some View {
    LabeledField(
      Text("Appearance", bundle: .module, comment: "The symbol and colour of the session."),
      help: model.usesProjectIcon
        ? Text("From the project folder until you pick one.", bundle: .module)
        : model.draft.appearance == nil
          ? Text("Derived from the name until you pick one.", bundle: .module)
          : model.appearanceComesFromTemplate
            ? Text("Given by the template — pick another if needed.", bundle: .module) : nil,
      issues: model.issues(for: .appearance)
    ) {
      HStack(alignment: .top, spacing: 14) {
        SessionBadge(
          appearance: model.draft.effectiveAppearance,
          icon: model.icons?.image(for: model.draft.effectiveAppearance.iconID), size: 46)

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            // Offered only when the folder has one, to come back to it after picking something
            // else.
            if let icon = model.draft.projectIcon {
              ProjectIconChoice(
                image: model.icons?.image(for: icon.id),
                isSelected: model.usesProjectIcon,
                select: { model.useProjectIcon() }
              )
            }
            ForEach(SessionAppearanceCatalog.symbolNames, id: \.self) { symbol in
              SymbolChoice(
                symbol: symbol,
                isSelected: !model.usesProjectIcon
                  && model.draft.effectiveAppearance.symbolName == symbol,
                select: { pickSymbol(symbol) }
              )
            }
          }
          HStack(spacing: 6) {
            ForEach(SessionAppearanceCatalog.colorHexValues, id: \.self) { hex in
              ColorChoice(
                hex: hex,
                isSelected: !model.usesProjectIcon
                  && model.draft.effectiveAppearance.colorHex == hex,
                select: { pickColor(hex) }
              )
            }
          }
        }
      }
    }
  }

  private var folderField: some View {
    LabeledField(
      Text("Working folder", bundle: .module),
      requirement: model.draft.resolvedWorkingDirectoryPath == nil ? .missing : .met,
      help: folderNotice.map { Text($0) }
        ?? (model.folderComesFromTemplate
          ? Text("Proposed by the template — change it if needed.", bundle: .module) : nil),
      issues: model.issues(for: .workingDirectory)
    ) {
      VStack(alignment: .leading, spacing: 8) {
        recentFolderCards
        folderPathField
      }
    }
  }

  /// What is said under the folder: the last folder gone, and a folder macOS guards, both when
  /// both apply — neither may hide the other.
  private var folderNotice: String? {
    let notices = [model.preselectionNotice, model.protectedLocationNotice].compactMap { $0 }
    return notices.isEmpty ? nil : notices.joined(separator: " ")
  }

  /// The folders sessions were created in, in one column like the agents: three, then the rest
  /// behind Show More (#39).
  @ViewBuilder
  private var recentFolderCards: some View {
    ForEach(Array(model.shownRecentFolders.enumerated()), id: \.element.id) { index, option in
      RecentFolderCard(
        option: option,
        isSelected: model.isSelected(option),
        select: { Task { await model.chooseRecentFolder(option) } },
        forget: { model.forget(option) }
      )
      .accessibilityIdentifier("new-session-recent-folder-\(index)")
    }
    if model.hiddenRecentFolderCount > 0 {
      ChoiceCard(isSelected: false, select: { model.isShowingMoreFolders.toggle() }) {
        Image(systemName: model.isShowingMoreFolders ? "chevron.up" : "ellipsis")
          .frame(width: 18)
        if model.isShowingMoreFolders {
          Text("Show Fewer", bundle: .module, comment: "Folds the recent folders back to three.")
        } else {
          Text(
            "Show \(model.hiddenRecentFolderCount) More", bundle: .module,
            comment: "Shows the other recent folders. The number of them.")
        }
        Spacer()
      }
      .accessibilityLabel(
        model.isShowingMoreFolders
          ? Text(
            "Show fewer recent folders", bundle: .module,
            comment: "VoiceOver: folds the recent folders back to three.")
          : Text(
            "Show \(model.hiddenRecentFolderCount) more recent folders", bundle: .module,
            comment: "VoiceOver: shows the other recent folders. The number of them.")
      )
      .accessibilityIdentifier("new-session-recent-folders-more")
    }
  }

  private var folderPathField: some View {
    HStack(spacing: 8) {
      TextField(
        String(localized: "Choose a folder", bundle: .module),
        text: Binding(
          get: { model.draft.workingDirectoryPath ?? "" },
          set: { model.draft.workingDirectoryPath = $0.isEmpty ? nil : $0 }
        )
      )
      .textFieldStyle(.roundedBorder)
      .focused($focus, equals: .draft(.workingDirectory))
      .accessibilityIdentifier("new-session-folder")

      Button(action: chooseFolder) {
        Text("Choose…", bundle: .module, comment: "Opens a panel to choose the working folder.")
      }
    }
  }

  /// The ticket the session works on (#69), pinned first in its web view. Optional: a branch named
  /// after a ticket gives one anyway.
  private var ticketField: some View {
    LabeledField(
      Text("Ticket", bundle: .module, comment: "The ticket the new session works on."),
      help: Text(
        "Optional. An address, or #12 in the working folder’s repository. Left empty, a branch named after a ticket gives one.",
        bundle: .module),
      issues: []
    ) {
      TextField(
        text: $model.draft.ticketText,
        prompt: Text(verbatim: "https://github.com/owner/repo/issues/12")
      ) {
        Text("Ticket", bundle: .module, comment: "The ticket the new session works on.")
      }
      .textFieldStyle(.roundedBorder)
      .accessibilityIdentifier("new-session-ticket")
    }
  }

  // MARK: - Composer

  /// The initial prompt, where a conversation is written to: the free text, or the template's
  /// rendering. Send and Add to To Do sit under it, with what they are waiting for.
  private var composer: some View {
    VStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 8) {
        if let rendered = model.renderedPrompt, let fill = model.draft.templateFill {
          renderedPrompt(rendered, of: fill)
        } else {
          PromptTextEditor(
            text: $model.draft.initialPrompt,
            minimumLines: 3,
            maximumLines: 12,
            placeholder: String(
              localized: "Describe the task: it will be the agent’s first message…",
              bundle: .module),
            accessibilityLabel: String(localized: "Initial prompt", bundle: .module),
            focusRequested: editorRequest == .draft(.initialPrompt),
            isBordered: false,
            onSubmit: submit
          )
          .focused($focus, equals: .draft(.initialPrompt))
          .accessibilityIdentifier("new-session-prompt")
        }
        ForEach(model.issues(for: .initialPrompt)) { issue in
          IssueLabel(issue: issue)
        }
        composerBar
      }
      .padding(12)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16).strokeBorder(.separator)
      }

      Text(
        "Return creates and launches · Shift-Return starts a new line · Option-Return adds to To Do · Escape sets the draft aside",
        bundle: .module
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .multilineTextAlignment(.center)
    }
  }

  /// The prompt exactly as it will be sent, with what was typed in bold and what is still missing
  /// named in its place.
  private func renderedPrompt(_ rendered: RenderedPrompt, of fill: PromptTemplateFill)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(
          "\(PromptSize.label(rendered.byteCount)) of \(PromptSize.label(AgentPromptLimits.argumentByteLimit)) · From “\(fill.template.trimmedName)”, revision \(String(fill.template.revision))",
          bundle: .module,
          comment:
            "The prompt's size, the most an agent accepts, the template's name and revision."
        )
        .font(.caption)
        .foregroundStyle(
          rendered.byteCount > AgentPromptLimits.argumentByteLimit ? Color.red : .secondary)
        Spacer()
        Button {
          model.editAsText()
          moveFocus(to: .draft(.initialPrompt))
        } label: {
          Text("Edit as Text", bundle: .module)
        }
        .controlSize(.small)
        .help(
          Text(
            "Turn the prompt into free text. The session will not refer to the template.",
            bundle: .module))
      }
      ScrollView {
        PromptPreviewText(rendered: rendered)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 140)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(
        Text("Prompt", bundle: .module, comment: "The prompt the agent is started with."))
    }
  }

  private var composerBar: some View {
    HStack(spacing: 8) {
      Button(action: chooseFiles) {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 24, height: 24)
          .overlay { Circle().strokeBorder(.separator) }
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(model.draft.templateFill != nil)
      .help(Text("Attach Files…", bundle: .module, comment: "Joins files to the prompt."))
      .accessibilityLabel(
        Text("Attach Files…", bundle: .module, comment: "Joins files to the prompt."))

      if let summary {
        Text(verbatim: summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 8)

      status
        .font(.caption)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)

      // Prepared now, started later with a swipe to In Progress: the prompt waits in To Do.
      Button {
        submit(launching: false)
      } label: {
        Text("Add to To Do", bundle: .module, comment: "Creates a session without launching it.")
      }
      .keyboardShortcut(.return, modifiers: .option)
      .disabled(!model.canSubmit)
      .accessibilityIdentifier("new-session-add-to-do")

      Button(action: submit) {
        Image(systemName: "arrow.up")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 28, height: 28)
          .background(
            Circle().fill(model.canSubmit ? Color.accentColor : Color.secondary.opacity(0.4))
          )
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      // Return goes to the line in a template's fields; ⌘↩ creates from anywhere in the draft.
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!model.canSubmit)
      .help(
        model.missingRequirement.map { Text(verbatim: $0) }
          ?? Text("Create & Launch", bundle: .module)
      )
      .accessibilityLabel(Text("Create & Launch", bundle: .module))
      .accessibilityHint(model.missingRequirement.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
      .accessibilityIdentifier("new-session-create")
    }
  }

  /// What the send waits for, the problems of the last try, or what an empty prompt means.
  @ViewBuilder
  private var status: some View {
    if let missing = model.missingRequirement {
      Text(verbatim: missing)
        .foregroundStyle(.orange)
    } else if model.hasSubmitted, !model.issues.isEmpty {
      Label {
        Text("\(model.issues.count) problems to fix", bundle: .module)
      } icon: {
        Image(systemName: "exclamationmark.circle")
      }
      .foregroundStyle(.red)
    } else if model.draft.trimmedPrompt.isEmpty {
      Text("Without a prompt, the agent starts with nothing to do.", bundle: .module)
        .foregroundStyle(.secondary)
    }
  }

  /// Where and with what, as the composer of a conversation names its agent: `app · Claude Code`.
  private var summary: String? {
    let folder = model.draft.resolvedWorkingDirectoryPath.map {
      ($0 as NSString).lastPathComponent
    }
    let parts = [folder, model.selectedAgent?.name].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Actions

  private func placeCaret() {
    // Back from a creation that was refused: the caret goes to what stopped it.
    moveFocus(
      to: firstIssueTarget ?? model.draft.templateFill.flatMap(firstEmptyField)
        ?? .draft(.initialPrompt))
  }

  private func moveFocus(to target: FocusTarget?) {
    focus = target
    editorRequest = target
  }

  private func firstEmptyField(in fill: PromptTemplateFill) -> FocusTarget? {
    let fields = fill.template.fields
    let empty = fields.first { fill.value(for: $0.name).isEmpty } ?? fields.first
    return empty.map { .templateField($0.name) }
  }

  /// Only these fields own a control that can take the keyboard: aiming the caret at any other
  /// would leave it nowhere at all.
  private static let focusableFields: Set<SessionDraftField> = [
    .name, .initialPrompt, .workingDirectory,
  ]

  private func submit() {
    submit(launching: true)
  }

  private func submit(launching: Bool) {
    guard model.canSubmit else {
      NSSound.beep()
      return
    }
    Task {
      guard await model.refusesBeforeCreating() else {
        submitted(launching)
        return
      }
      moveFocus(to: firstIssueTarget)
    }
  }

  private var firstIssueTarget: FocusTarget? {
    model.issues.lazy.compactMap { issue -> FocusTarget? in
      if issue.field == .templateField, let key = issue.fieldKey {
        return .templateField(key)
      }
      return Self.focusableFields.contains(issue.field) ? .draft(issue.field) : nil
    }.first
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

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = String(
      localized: "Choose", bundle: .module, comment: "The button of the folder panel.")
    // The panel opens on the home directory when nothing is chosen yet. The draft itself
    // proposes no folder — accepting one that contains Desktop, Documents and Downloads would
    // send an agent into them with nothing said — but the panel has to start somewhere.
    panel.directoryURL = URL(
      fileURLWithPath: model.draft.resolvedWorkingDirectoryPath ?? NSHomeDirectory(),
      isDirectory: true
    )
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.folderChosen(url.path) }
  }
}

/// A row of the options: its title on the left, the control on the right, and under it the
/// problems, else the help. A required option says whether it is filled.
private struct LabeledField<Content: View>: View {
  enum Requirement {
    case missing
    case met
  }

  static var titleWidth: CGFloat { 132 }

  private let title: Text
  private let requirement: Requirement?
  private let help: Text?
  private let issues: [SessionDraftIssue]
  private let content: Content

  init(
    _ title: Text,
    requirement: Requirement? = nil,
    help: Text? = nil,
    issues: [SessionDraftIssue],
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.requirement = requirement
    self.help = help
    self.issues = issues
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .trailing, spacing: 4) {
        title
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
        switch requirement {
        case .missing:
          Text("Required", bundle: .module, comment: "An option of a new session to fill.")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.15), in: Capsule())
        case .met:
          Image(systemName: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .accessibilityLabel(
              Text("Filled", bundle: .module, comment: "VoiceOver: a required option, filled."))
        case nil:
          EmptyView()
        }
      }
      .frame(width: Self.titleWidth, alignment: .trailing)

      VStack(alignment: .leading, spacing: 5) {
        content
        ForEach(issues) { issue in
          IssueLabel(issue: issue)
        }
        if let help, issues.isEmpty {
          help
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
      Text(verbatim: "\(issue.message) \(issue.remedy)")
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: "\(issue.message) \(issue.remedy)"))
  }
}

/// One agent in a list the user picks from, with its state and, when it cannot run, its remedy.
struct AgentChoiceRow: View {
  let agent: AgentOption
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    // Unusable agents stay visible and readable, but cannot be chosen.
    ChoiceCard(isSelected: isSelected, isEnabled: agent.isUsable, select: select) {
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
          .help(Text("The agent will ask you to sign in inside the terminal.", bundle: .module))
      }
    }
    .accessibilityLabel(
      Text(
        verbatim: agent.isUsable
          ? "\(agent.name). \(agent.status)"
          : "\(agent.name). \(agent.status) \(agent.remedy)")
    )
  }
}

/// One choice in a list the user picks one item from — an agent, a recent folder: tinted and
/// outlined once chosen, dimmed when it cannot be. One component, so every such list looks alike.
struct ChoiceCard<Content: View>: View {
  let isSelected: Bool
  var isEnabled = true
  let select: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    Button(action: select) {
      HStack(spacing: 10) {
        content
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
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.6)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

/// A folder a session was created in, offered again (#39).
struct RecentFolderCard: View {
  let option: RecentFolderOption
  let isSelected: Bool
  let select: () -> Void
  let forget: () -> Void

  private var isMissing: Bool { option.availability == .missing }

  var body: some View {
    // A folder that has gone stays listed — a volume unplugged for now comes back — but cannot
    // be chosen.
    ChoiceCard(isSelected: isSelected, isEnabled: !isMissing, select: select) {
      Image(systemName: isMissing ? "questionmark.folder" : "folder")
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: option.name)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.middle)
        Group {
          if isMissing {
            Text("Folder not found", bundle: .module, comment: "A recent folder that has gone.")
          } else {
            Text(verbatim: option.location)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      }
      Spacer()
    }
    .help(Text(verbatim: option.displayPath))
    .contextMenu {
      Button(action: forget) {
        Text("Remove from Recents", bundle: .module, comment: "Forgets a recent folder.")
      }
      Button {
        NSWorkspace.shared.activateFileViewerSelecting([
          URL(fileURLWithPath: RecentFolder.lexicalKey(of: option.folder.path))
        ])
      } label: {
        Text("Show in Finder", bundle: .module)
      }
      .disabled(isMissing)
    }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAction(
      named: Text("Remove from Recents", bundle: .module, comment: "Forgets a recent folder."),
      forget)
  }

  private var accessibilityLabel: Text {
    guard isMissing else { return Text(verbatim: "\(option.name), \(option.displayPath)") }
    return Text(
      "\(option.name), \(option.displayPath). Folder not found", bundle: .module,
      comment: "VoiceOver: a recent folder that has gone. Its name, then its path.")
  }
}

struct SymbolChoice: View {
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

/// The project's own icon, among the symbols of the catalogue.
struct ProjectIconChoice: View {
  let image: NSImage?
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Group {
        if let image {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(3)
        } else {
          Image(systemName: "photo")
        }
      }
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
    .help(Text("Project icon", bundle: .module, comment: "The icon found in the working folder."))
    .accessibilityLabel(
      Text("Project icon", bundle: .module, comment: "The icon found in the working folder.")
    )
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

struct ColorChoice: View {
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
    .accessibilityLabel(
      Text("Accent \(hex)", bundle: .module, comment: "VoiceOver: a colour, by its hex code.")
    )
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

/// The rendered prompt, with the values typed in bold and the fields still empty named in their
/// place — `‹Merge request URL›` — so what is missing is seen where it is missing.
struct PromptPreviewText: View {
  let rendered: RenderedPrompt

  var body: some View {
    Text(attributed)
      .font(.callout)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var attributed: AttributedString {
    var result = AttributedString()
    for part in rendered.parts {
      switch part {
      case .text(let text):
        result += AttributedString(text)
      case .value(_, let text):
        var value = AttributedString(text)
        value.inlinePresentationIntent = .stronglyEmphasized
        result += value
      case .unmatched(_, let label, _):
        var unmatched = AttributedString(
          String(
            localized: "‹\(label): no match›", bundle: .module,
            comment: "In a prompt preview: a field whose pattern found nothing in its value."))
        unmatched.foregroundColor = .orange
        result += unmatched
      case .missing(_, let label, _, let isRequired):
        guard isRequired else { continue }
        var missing = AttributedString("‹\(label)›")
        missing.foregroundColor = .secondary
        result += missing
      }
    }
    if result.characters.isEmpty {
      var empty = AttributedString(String(localized: "The prompt is empty.", bundle: .module))
      empty.foregroundColor = .secondary
      return empty
    }
    return result
  }
}
