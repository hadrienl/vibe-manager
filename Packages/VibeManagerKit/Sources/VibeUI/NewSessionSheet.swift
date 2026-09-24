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
  private let created: (SessionCreation) -> Void
  private let cancelled: () -> Void
  /// Opens the templates in the settings. `nil`: the sheet offers no way there.
  private let manageTemplates: (() -> Void)?

  public init(
    model: NewSessionModel,
    defaultWorkingDirectoryPath: String? = nil,
    created: @escaping (SessionCreation) -> Void,
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
        templateField
        nameField
        if model.draft.templateFill != nil {
          templateFields
          previewField
        } else {
          promptField
        }
        folderField
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
        .focused($focus, equals: .draft(.name))
        .accessibilityIdentifier("new-session-name")
    }
  }

  @ViewBuilder
  private var templateField: some View {
    LabeledField(
      "Template",
      help: model.templates.isEmpty
        ? "No templates yet — Manage… to write one, or add the examples." : nil,
      issues: []
    ) {
      HStack(spacing: 8) {
        Picker(
          "Template",
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
          Text("None — free prompt").tag(PromptTemplateID?.none)
          if !model.templates.isEmpty {
            Divider()
          }
          ForEach(model.templates) { template in
            Label(
              template.trimmedName,
              systemImage: template.appearance?.symbolName ?? "text.badge.plus"
            )
            .tag(PromptTemplateID?.some(template.id))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)

        if let manageTemplates {
          Button("Manage…", action: manageTemplates)
            .controlSize(.small)
        }
      }
    }
    if model.isTemplateStale {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary)
        Text("This template changed since you picked it.")
          .font(.caption)
        Button("Reload") { model.reloadTemplate() }
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
          field.isRequired ? "\(field.label) *" : field.label,
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
          .accessibilityValue(field.isRequired ? "Required" : "")
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
      LabeledField("Prompt", issues: model.issues(for: .initialPrompt)) {
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
              "\(PromptSize.label(rendered.byteCount)) of \(PromptSize.label(AgentPromptLimits.argumentByteLimit)) · From “\(fill.template.trimmedName)”, revision \(fill.template.revision)"
            )
            .font(.caption)
            .foregroundStyle(
              rendered.byteCount > AgentPromptLimits.argumentByteLimit ? Color.red : .secondary)
            Spacer()
            Button("Edit as Text") {
              model.editAsText()
              moveFocus(to: .draft(.initialPrompt))
            }
            .controlSize(.small)
            .help("Turn the prompt into free text. The session will not refer to the template.")
          }
        }
      }
    }
  }

  private var promptField: some View {
    LabeledField(
      "Initial prompt",
      help: "Optional — handed to the agent as its first message.",
      issues: model.issues(for: .initialPrompt)
    ) {
      PromptTextEditor(
        text: $model.draft.initialPrompt,
        accessibilityLabel: "Initial prompt",
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
          AgentChoiceRow(
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
        : model.appearanceComesFromTemplate
          ? "Given by the template — pick another if needed." : nil,
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
      "Working folder",
      help: model.protectedLocationNotice
        ?? (model.folderComesFromTemplate
          ? "Proposed by the template — change it if needed." : nil),
      issues: model.issues(for: .workingDirectory)
    ) {
      HStack(spacing: 8) {
        TextField(
          "Choose a folder",
          text: Binding(
            get: { model.draft.workingDirectoryPath ?? "" },
            set: { model.draft.workingDirectoryPath = $0.isEmpty ? nil : $0 }
          )
        )
        .textFieldStyle(.roundedBorder)
        .focused($focus, equals: .draft(.workingDirectory))
        .accessibilityIdentifier("new-session-folder")

        Button("Choose…", action: chooseFolder)
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
        .accessibilityIdentifier("new-session-create")
        // Return goes to the line in a prompt; ⌘↩ creates from anywhere in the form.
        .background {
          Button("Create & Launch", action: submit)
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

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
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
    .accessibilityLabel(Text("Accent \(hex)"))
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
        var unmatched = AttributedString("‹\(label): no match›")
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
      var empty = AttributedString("The prompt is empty.")
      empty.foregroundColor = .secondary
      return empty
    }
    return result
  }
}
