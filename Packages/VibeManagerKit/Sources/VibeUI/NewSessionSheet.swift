import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

public struct NewSessionSheet: View {
  /// Bindable, not `@State`: the fields need bindings, but the model belongs to `AppModel` and
  /// must not be frozen at the value this view was first given.
  @Bindable private var model: NewSessionModel
  @FocusState private var focus: FocusTarget?
  /// The prompt areas are AppKit text views, which SwiftUI's focus does not reach: where the caret
  /// was sent is kept here too, and they take it themselves.
  @State private var editorRequest: FocusTarget?

  /// What can hold the keyboard: the draft's own fields, and the ones a template adds.
  enum FocusTarget: Hashable {
    case draft(SessionDraftField)
    case templateField(String)
  }

  private let defaultWorkingDirectoryPath: String?
  /// The session, and whether to launch it now or leave it in To Do (#80).
  private let created: (SessionCreation, Bool) -> Void
  private let cancelled: () -> Void
  /// Opens the templates in the settings. `nil`: the sheet offers no way there.
  private let manageTemplates: (() -> Void)?

  public init(
    model: NewSessionModel,
    defaultWorkingDirectoryPath: String? = nil,
    created: @escaping (SessionCreation, Bool) -> Void,
    cancelled: @escaping () -> Void,
    manageTemplates: (() -> Void)? = nil
  ) {
    _model = Bindable(model)
    self.defaultWorkingDirectoryPath = defaultWorkingDirectoryPath
    self.created = created
    self.cancelled = cancelled
    self.manageTemplates = manageTemplates
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      form
      Divider()
      footer
    }
    .frame(width: 640, height: 760)
    .task {
      await model.load(defaultWorkingDirectoryPath: defaultWorkingDirectoryPath)
      moveFocus(to: model.draft.templateFill.flatMap(firstEmptyField) ?? .draft(.name))
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("New Session", bundle: .module, comment: "Title of the New Session sheet.")
        .font(.title2.weight(.semibold))
      Text("The terminal and the agent start as soon as the session is created.", bundle: .module)
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
        templateField
        nameField
        if model.draft.templateFill != nil {
          templateFields
          previewField
        } else {
          promptField
        }
        folderField
        ticketField
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
    LabeledField(
      Text("Name", bundle: .module, comment: "The name of the new session."),
      issues: model.issues(for: .name)
    ) {
      TextField(
        String(localized: "What are you working on?", bundle: .module),
        text: $model.draft.name
      )
      .textFieldStyle(.roundedBorder)
      .focused($focus, equals: .draft(.name))
      .accessibilityIdentifier("new-session-name")
    }
  }

  @ViewBuilder
  private var templateField: some View {
    LabeledField(
      Text("Template", bundle: .module, comment: "The prompt template the session starts from."),
      help: model.templates.isEmpty
        ? Text(
          "No templates yet — Manage… to write one, or add the examples.", bundle: .module,
          comment: "Manage… is the button next to the template picker.") : nil,
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
          Text("Template", bundle: .module, comment: "The prompt template the session starts from.")
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
      .padding(.leading, 130)
      .accessibilityElement(children: .combine)
    }
  }

  /// One control per field of the template, in the order the text reads them.
  @ViewBuilder
  private var templateFields: some View {
    if let fill = model.draft.templateFill {
      ForEach(fill.template.fields) { field in
        LabeledField(
          Text(verbatim: field.isRequired ? "\(field.label) *" : field.label),
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

  /// The prompt exactly as it will be sent, with what was typed in bold and what is still missing
  /// named in its place.
  @ViewBuilder
  private var previewField: some View {
    if let rendered = model.renderedPrompt, let fill = model.draft.templateFill {
      LabeledField(
        Text("Prompt", bundle: .module, comment: "The prompt the agent is started with."),
        issues: model.issues(for: .initialPrompt)
      ) {
        VStack(alignment: .leading, spacing: 6) {
          ScrollView {
            PromptPreviewText(rendered: rendered)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
          }
          .frame(maxHeight: 180)
          .fixedSize(horizontal: false, vertical: true)
          .background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
          }

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
        }
      }
    }
  }

  private var promptField: some View {
    LabeledField(
      Text("Initial prompt", bundle: .module),
      help: Text("Optional — handed to the agent as its first message.", bundle: .module),
      issues: model.issues(for: .initialPrompt)
    ) {
      PromptTextEditor(
        text: $model.draft.initialPrompt,
        accessibilityLabel: String(localized: "Initial prompt", bundle: .module),
        focusRequested: editorRequest == .draft(.initialPrompt)
      )
      .focused($focus, equals: .draft(.initialPrompt))
      .accessibilityIdentifier("new-session-prompt")
    }
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

  private var agentField: some View {
    LabeledField(
      Text("Agent", bundle: .module, comment: "The coding agent the session runs."),
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
      help: model.draft.appearance == nil
        ? Text("Derived from the name until you pick one.", bundle: .module)
        : model.appearanceComesFromTemplate
          ? Text("Given by the template — pick another if needed.", bundle: .module) : nil,
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

  private var folderField: some View {
    LabeledField(
      Text("Working folder", bundle: .module),
      help: model.protectedLocationNotice.map { Text($0) }
        ?? (model.folderComesFromTemplate
          ? Text("Proposed by the template — change it if needed.", bundle: .module) : nil),
      issues: model.issues(for: .workingDirectory)
    ) {
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

  private var footer: some View {
    HStack {
      if model.hasSubmitted, !model.issues.isEmpty {
        Label {
          Text("\(model.issues.count) problems to fix", bundle: .module)
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .font(.caption)
        .foregroundStyle(.red)
      } else {
        Text(
          "Cancel creates nothing — no session, no process.", bundle: .module,
          comment: "Cancel is the button of the sheet."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Button(role: .cancel, action: cancelled) {
        Text("Cancel", bundle: .module)
      }
      .keyboardShortcut(.cancelAction)
      // Prepared now, started later with a swipe to In Progress: the prompt waits in To Do.
      Button {
        submit(launching: false)
      } label: {
        Text("Add to To Do", bundle: .module, comment: "Creates a session without launching it.")
      }
      .disabled(!model.canSubmit)
      .accessibilityIdentifier("new-session-add-to-do")
      Button(action: submit) {
        Text("Create & Launch", bundle: .module)
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(!model.canSubmit)
      .accessibilityIdentifier("new-session-create")
      // Return goes to the line in a prompt; ⌘↩ creates from anywhere in the form.
      .background {
        Button(action: submit) {
          Text("Create & Launch", bundle: .module)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canSubmit)
        .hidden()
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 13)
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
    Task {
      guard let creation = await model.submit() else {
        let target =
          model.issues.lazy.compactMap { issue -> FocusTarget? in
            if issue.field == .templateField, let key = issue.fieldKey {
              return .templateField(key)
            }
            return Self.focusableFields.contains(issue.field) ? .draft(issue.field) : nil
          }.first
        moveFocus(to: target)
        return
      }
      created(creation, launching)
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

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = String(
      localized: "Choose", bundle: .module, comment: "The button of the folder panel.")
    // The panel opens on the home directory when nothing is chosen yet. The sheet itself
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

private struct LabeledField<Content: View>: View {
  private let title: Text
  private let help: Text?
  private let issues: [SessionDraftIssue]
  private let content: Content

  init(
    _ title: Text,
    help: Text? = nil,
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
      title
        .foregroundStyle(.secondary)
        .frame(width: 118, alignment: .trailing)

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
            .help(Text("The agent will ask you to sign in inside the terminal.", bundle: .module))
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
      Text(
        verbatim: agent.isUsable
          ? "\(agent.name). \(agent.status)"
          : "\(agent.name). \(agent.status) \(agent.remedy)")
    )
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
