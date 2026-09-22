import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

public struct NewSessionSheet: View {
  @State private var model: NewSessionModel
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
    _model = State(initialValue: model)
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
    .frame(width: 640, height: 700)
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
        agentField
        modelField
        appearanceField
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
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
            select: { model.draft.providerID = agent.id.rawValue }
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
      issues: []
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
    LabeledField("Working folder", issues: model.issues(for: .workingDirectory)) {
      HStack(spacing: 8) {
        TextField(
          "Choose a folder",
          text: Binding(
            get: { model.draft.workingDirectoryPath ?? "" },
            set: { model.draft.workingDirectoryPath = $0.isEmpty ? nil : $0 }
          )
        )
        .textFieldStyle(.roundedBorder)
        .focused($focus, equals: .workingDirectory)

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
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 13)
  }

  private func submit() {
    Task {
      guard let creation = await model.submit() else {
        focus = model.issues.first?.field
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
    if let path = model.draft.resolvedWorkingDirectoryPath {
      panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.draft.workingDirectoryPath = url.path
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
