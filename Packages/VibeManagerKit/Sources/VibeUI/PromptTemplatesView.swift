import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// The Prompt Templates window: the list on the left, in the user's order, and the template being
/// edited on the right, with a preview of what it gives.
public struct PromptTemplatesView: View {
  @Bindable private var model: PromptTemplateLibraryModel
  @State private var pendingDelete: PromptTemplate?
  @State private var isImporting = false
  @State private var export: ExportRequest?
  @FocusState private var isNameFocused: Bool

  public init(model: PromptTemplateLibraryModel) {
    _model = Bindable(model)
  }

  public var body: some View {
    HSplitView {
      sidebar
        .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
      detail
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 720, minHeight: 520)
    .task { await model.load() }
    .confirmationDialog(
      "Save the changes to “\(model.editing?.trimmedName ?? "")”?",
      isPresented: Binding(
        get: { model.pendingNavigation != nil },
        set: { if !$0 { model.dismissPendingNavigation() } }
      ),
      presenting: model.pendingNavigation
    ) { navigation in
      Button("Save") { Task { await model.resolve(navigation, saving: true) } }
        .disabled(!model.canSave)
      Button("Don't Save", role: .destructive) {
        Task { await model.resolve(navigation, saving: false) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Your changes are lost if you don't save them.")
    }
    .alert(
      "Delete “\(pendingDelete?.trimmedName ?? "")”?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      presenting: pendingDelete
    ) { template in
      // The template comes from the alert, not from `pendingDelete`: SwiftUI clears that when it
      // dismisses the alert, before it runs this button.
      Button("Delete", role: .destructive) {
        Task { await model.delete(template.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Sessions created from it keep their prompt.")
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
      guard case .success(let url) = result else { return }
      importFile(at: url)
    }
    .fileExporter(
      isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
      document: export.map { TemplateFile(data: $0.data) },
      contentType: .json,
      defaultFilename: export?.filename ?? "Prompt Templates"
    ) { _ in
      export = nil
    }
    .sheet(
      isPresented: Binding(
        get: { model.pendingImport != nil }, set: { if !$0 { model.cancelImport() } })
    ) {
      ImportReviewSheet(model: model)
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first else { return false }
      importFile(at: url)
      return true
    }
  }

  // MARK: - The list

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(
        selection: Binding(
          get: { model.selectedID },
          set: { model.requestSelect($0) }
        )
      ) {
        if model.isNew, let editing = model.editing {
          Label(
            editing.trimmedName.isEmpty ? "Untitled Template" : editing.trimmedName,
            systemImage: "square.and.pencil"
          )
          .italic()
          .tag(Optional(editing.id))
        }
        ForEach(model.all) { template in
          row(template)
        }
        .onMove { source, destination in
          guard let first = source.first else { return }
          let id = model.all[first].id
          let position = destination > first ? destination - 1 : destination
          Task { await model.move(id, toPosition: position) }
        }
      }
      .listStyle(.sidebar)
      // ⌫ in the list, as in the Finder and Mail: the same question as the − button.
      .onDeleteCommand(perform: requestDeleteSelection)

      Divider()
      HStack(spacing: 4) {
        Button {
          model.newTemplate()
          isNameFocused = true
        } label: {
          Image(systemName: "plus")
        }
        .help("New Template")
        .accessibilityLabel("New Template")
        .disabled(model.isReadOnly)

        Button(action: requestDeleteSelection) {
          Image(systemName: "minus")
        }
        .help(model.isNew ? "Discard This Template" : "Delete Template")
        .accessibilityLabel(model.isNew ? "Discard This Template" : "Delete Template")
        .disabled(model.isReadOnly || model.editing == nil)

        Menu {
          actionsMenu
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
        Spacer()
      }
      .buttonStyle(.borderless)
      .padding(8)
    }
  }

  private func row(_ template: PromptTemplate) -> some View {
    Text(template.trimmedName)
      .lineLimit(1)
      .tag(Optional(template.id))
      .contextMenu { templateActions(for: template) }
  }

  @ViewBuilder
  private var actionsMenu: some View {
    if let selected = model.savedEditing {
      templateActions(for: selected)
      Divider()
    }
    Button("Add Examples") { Task { await model.addExamples() } }
      .disabled(!model.canAddExamples)
    Divider()
    Button("Import…") { isImporting = true }
      .disabled(model.isReadOnly || !model.canExchange)
    Button("Export All…") { requestExport(ids: nil) }
      .disabled(model.all.isEmpty || !model.canExchange)
  }

  @ViewBuilder
  private func templateActions(for template: PromptTemplate) -> some View {
    Button("Duplicate") { Task { await model.duplicate(template.id) } }
      .disabled(model.isReadOnly)
    Button("Move Up") { Task { await model.move(template.id, by: -1) } }
      .keyboardShortcut(.upArrow, modifiers: [.command, .control])
      .disabled(!model.canMove(template.id, by: -1))
    Button("Move Down") { Task { await model.move(template.id, by: 1) } }
      .keyboardShortcut(.downArrow, modifiers: [.command, .control])
      .disabled(!model.canMove(template.id, by: 1))
    Button("Delete…", role: .destructive) { pendingDelete = template }
      .disabled(model.isReadOnly)
    Button("Export “\(template.trimmedName)”…") {
      requestExport(ids: [template.id])
    }
    .disabled(!model.canExchange)
  }

  // MARK: - The editor

  @ViewBuilder
  private var detail: some View {
    VStack(spacing: 0) {
      banners
      if let editing = model.editing {
        editor(editing)
      } else if model.all.isEmpty && model.state == .ready {
        emptyLibrary
      } else {
        Text(model.state == .loading ? "Loading templates…" : "Select a template.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  @ViewBuilder
  private var banners: some View {
    if case .unreadable(let reason) = model.state {
      Banner(symbol: "exclamationmark.triangle", text: reason) {
        if let url = model.fileURL {
          Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      }
    }
    if let failure = model.failure {
      Banner(symbol: "exclamationmark.triangle", text: failure) {
        Button("Dismiss") { model.dismissFailure() }
      }
    }
    if let summary = model.importSummary {
      Banner(symbol: "checkmark.circle", text: summary) {
        Button("Dismiss") { model.dismissImportSummary() }
      }
    }
  }

  private var emptyLibrary: some View {
    VStack(spacing: 12) {
      Text("No templates yet.")
        .font(.title3)
      Text(
        "A template is a prompt with fields to fill in — “Review {{url}}” — ready to start a session from."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 360)
      HStack {
        Button("Add Examples") { Task { await model.addExamples() } }
        Button("New Template") {
          model.newTemplate()
          isNameFocused = true
        }
        .buttonStyle(.borderedProminent)
      }
      .disabled(model.isReadOnly)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func editor(_ editing: PromptTemplate) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          EditorRow("Name", issues: issues(for: .name)) {
            TextField("What is it for?", text: binding(\.name))
              .textFieldStyle(.roundedBorder)
              .focused($isNameFocused)
          }
          EditorRow(
            "Session name",
            help: "Optional — the name of the sessions made from it, with the same {{fields}}.",
            issues: issues(for: .sessionName)
          ) {
            TextField("Review {{url}}", text: binding(\.sessionNamePattern))
              .textFieldStyle(.roundedBorder)
          }
          EditorRow(
            "Prompt",
            help:
              "{{name}} is a field, {{name?}} an optional one, {{name|/regex/}} keeps part of it. Write \\{{ to keep the braces as text.",
            issues: issues(for: .body)
          ) {
            VStack(alignment: .leading, spacing: 5) {
              PromptTextEditor(
                text: binding(\.body),
                accessibilityLabel: "Prompt",
                highlightsPlaceholders: true,
                isEditable: !model.isReadOnly
              )
              // A text view of its own per template, so ⌘Z never brings back another one's text.
              .id(editing.id)
              malformedNotice(editing)
            }
          }
          fieldsSection(editing)
          previewSection(editing)
        }
        .padding(20)
        .disabled(model.isReadOnly)
      }
      Divider()
      footer(editing)
    }
  }

  @ViewBuilder
  private func malformedNotice(_ editing: PromptTemplate) -> some View {
    let parsed = PromptTemplateSyntax.parse(editing.body)
    if let first = parsed.malformed.first {
      let text = String(
        decoding: Array(editing.body.utf16)[first], as: UTF16.self)
      Text("\(text) is not a field — names use letters, digits, - and _ — so it stays as text.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func fieldsSection(_ editing: PromptTemplate) -> some View {
    let fields = editing.fields
    EditorRow(
      "Fields",
      help: fields.isEmpty ? "Fields appear here as you write {{name}} in the text." : nil,
      issues: []
    ) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(fields) { field in
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Text(field.name)
                .font(.callout.monospaced())
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
              TextField(
                PromptTemplateField.derivedLabel(for: field.name),
                text: settingsBinding(field.name, \.label)
              )
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Label of \(field.name)")
            }
            HStack(spacing: 12) {
              Spacer().frame(width: 90)
              Toggle(
                "Required",
                isOn: Binding(
                  get: { field.isRequired },
                  set: { model.setRequired($0, for: field.name) }
                ))
              Toggle(
                "Multiline",
                isOn: Binding(
                  get: { field.isMultiline },
                  set: { value in model.updateSettings(for: field.name) { $0.isMultiline = value } }
                ))
              TextField("Hint", text: settingsBinding(field.name, \.help))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Hint of \(field.name)")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            // One value to try, for this field's patterns and for the preview below alike.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("Try")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
              VStack(alignment: .leading, spacing: 4) {
                TextField(
                  field.help ?? "A value to try — not saved",
                  text: Binding(
                    get: { model.sampleValues[field.name] ?? "" },
                    set: { model.sampleValues[field.name] = $0 }
                  )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Value to try for \(field.label)")
                ExtractionResultsView(
                  results: PromptTemplateFill(template: editing, values: model.sampleValues)
                    .extractions(for: field.name),
                  showsPlaces: true
                )
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func previewSection(_ editing: PromptTemplate) -> some View {
    EditorRow(
      "Preview", help: "Made with the values tried above.", issues: []
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if let name = model.preview?.sessionName, !name.isEmpty {
          Text("Session: \(name)")
            .font(.callout.weight(.medium))
            .textSelection(.enabled)
        }
        if let preview = model.preview {
          PromptPreviewText(rendered: preview)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          Text(
            "\(PromptSize.label(preview.byteCount)) of \(PromptSize.label(AgentPromptLimits.argumentByteLimit))"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func footer(_ editing: PromptTemplate) -> some View {
    HStack {
      if model.isEdited {
        Text(model.isNew ? "Not saved yet" : "Edited")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let saved = model.savedEditing {
        Text("Revision \(saved.revision)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Revert") { model.revert() }
        .disabled(!model.isEdited)
      Button("Save") { Task { await model.save() } }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSave)
        .background {
          Button("Save") { Task { await model.save() } }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canSave)
            .hidden()
        }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: -

  private func issues(for field: PromptTemplateIssueField) -> [PromptTemplateIssue] {
    guard model.isEdited else { return [] }
    return model.issues.filter { $0.field == field }
  }

  private func binding(_ keyPath: WritableKeyPath<PromptTemplate, String>) -> Binding<String> {
    Binding(
      get: { model.editing?[keyPath: keyPath] ?? "" },
      set: { model.editing?[keyPath: keyPath] = $0 }
    )
  }

  private func settingsBinding(
    _ key: String, _ keyPath: WritableKeyPath<PromptTemplateFieldSettings, String?>
  ) -> Binding<String> {
    Binding(
      get: { model.editing?.settings(for: key)?[keyPath: keyPath] ?? "" },
      set: { value in
        model.updateSettings(for: key) { $0[keyPath: keyPath] = value.isEmpty ? nil : value }
      }
    )
  }

  /// A template never saved is only discarded; a saved one is deleted once the user confirms.
  private func requestDeleteSelection() {
    guard !model.isReadOnly else { return }
    if model.isNew {
      model.revert()
    } else if let saved = model.savedEditing {
      pendingDelete = saved
    }
  }

  private func importFile(at url: URL) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else { return }
    model.prepareImport(data)
  }

  private func requestExport(ids: Set<PromptTemplateID>?) {
    guard let data = model.exportData(ids: ids) else {
      return
    }
    var name = "Prompt Templates"
    if let ids, ids.count == 1, let id = ids.first {
      name = model.library.template(id: id)?.trimmedName ?? "Prompt Template"
    }
    export = ExportRequest(data: data, filename: name)
  }
}

private struct ExportRequest {
  let data: Data
  let filename: String
}

/// The exported file, handed to the save panel.
private struct TemplateFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

/// What an import will do, template by template, before anything is changed.
private struct ImportReviewSheet: View {
  @Bindable var model: PromptTemplateLibraryModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Import Templates")
        .font(.title2.weight(.semibold))
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 10)
      Divider()
      if let plan = model.pendingImport?.plan {
        List(plan.entries) { entry in
          HStack(alignment: .firstTextBaseline) {
            Text(entry.template.trimmedName.isEmpty ? "Untitled" : entry.template.trimmedName)
              .lineLimit(1)
            Spacer()
            outcome(entry)
          }
        }
        .frame(minHeight: 220)
      }
      Divider()
      HStack {
        Text("Nothing is replaced unless you choose it.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { model.cancelImport() }
          .keyboardShortcut(.cancelAction)
        Button("Import") { Task { await model.applyImport() } }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!(model.pendingImport?.plan.hasWork ?? false))
      }
      .padding(16)
    }
    .frame(width: 520)
  }

  @ViewBuilder
  private func outcome(_ entry: PromptTemplateImportPlan.Entry) -> some View {
    switch entry.outcome {
    case .new:
      Text("New").foregroundStyle(.secondary)
    case .identical:
      Text("Identical — skipped").foregroundStyle(.secondary)
    case .skipped(let reason):
      Text("Skipped: \(reason)")
        .foregroundStyle(.orange)
        .font(.caption)
        .lineLimit(2)
    case .changed:
      Picker(
        "Changed",
        selection: Binding(
          get: { model.pendingImport?.replacing.contains(entry.id) ?? false },
          set: { replace in
            if replace {
              model.pendingImport?.replacing.insert(entry.id)
            } else {
              model.pendingImport?.replacing.remove(entry.id)
            }
          }
        )
      ) {
        Text("Keep Both").tag(false)
        Text("Replace").tag(true)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .accessibilityLabel("\(entry.template.trimmedName) changed")
    }
  }
}

private struct Banner<Actions: View>: View {
  let symbol: String
  let text: String
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      actions
        .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .bottom) { Divider() }
  }
}

private struct EditorRow<Content: View>: View {
  private let title: String
  private let help: String?
  private let issues: [PromptTemplateIssue]
  private let content: Content

  init(
    _ title: String, help: String? = nil, issues: [PromptTemplateIssue],
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
        .frame(width: 100, alignment: .trailing)
      VStack(alignment: .leading, spacing: 5) {
        content
        ForEach(issues) { issue in
          Label("\(issue.message) \(issue.remedy)", systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let help, issues.isEmpty {
          Text(help)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
