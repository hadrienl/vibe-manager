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

  /// Laid out inside the settings window, under its tabs: nothing here draws in the title bar.
  /// A sidebar list, or a background that is not bounded by a shape, would reach up behind the
  /// tabs and cut the window's top into bands.
  public var body: some View {
    VStack(spacing: 0) {
      banners
      HStack(alignment: .top, spacing: 16) {
        sidebar
          .frame(width: 220)
        detail
          .frame(minWidth: 740, maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding(16)
    }
    .frame(minWidth: 1000, idealWidth: 1180, minHeight: 600, idealHeight: 700)
    .task { await model.load() }
    .confirmationDialog(
      Text(
        "Save the changes to “\(model.editing?.trimmedName ?? "")”?", bundle: .module,
        comment: "The name of the prompt template being edited."),
      isPresented: Binding(
        get: { model.pendingNavigation != nil },
        set: { if !$0 { model.dismissPendingNavigation() } }
      ),
      presenting: model.pendingNavigation
    ) { navigation in
      Button(LocalizedStringResource("Save", bundle: .module)) {
        Task { await model.resolve(navigation, saving: true) }
      }
      .disabled(!model.canSave)
      Button(LocalizedStringResource("Don't Save", bundle: .module), role: .destructive) {
        Task { await model.resolve(navigation, saving: false) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {}
    } message: { _ in
      Text("Your changes are lost if you don't save them.", bundle: .module)
    }
    .alert(
      Text(
        "Delete “\(pendingDelete?.trimmedName ?? "")”?", bundle: .module,
        comment: "The name of the prompt template to delete."),
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      presenting: pendingDelete
    ) { template in
      // The template comes from the alert, not from `pendingDelete`: SwiftUI clears that when it
      // dismisses the alert, before it runs this button.
      Button(LocalizedStringResource("Delete", bundle: .module), role: .destructive) {
        Task { await model.delete(template.id) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {}
    } message: { _ in
      Text("Sessions created from it keep their prompt.", bundle: .module)
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
      guard case .success(let url) = result else { return }
      importFile(at: url)
    }
    .fileExporter(
      isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
      document: export.map { TemplateFile(data: $0.data) },
      contentType: .json,
      defaultFilename: export?.filename ?? Self.exportName
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
            editing.trimmedName.isEmpty ? Self.untitledName : editing.trimmedName,
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
      .listStyle(.bordered(alternatesRowBackgrounds: false))
      // ⌫ in the list, as in the Finder and Mail: the same question as the − button.
      .onDeleteCommand(perform: requestDeleteSelection)

      // Under the list, as in the Accounts settings of macOS: add, remove, and the rest.
      HStack(spacing: 4) {
        Button {
          model.newTemplate()
          isNameFocused = true
        } label: {
          Image(systemName: "plus")
        }
        .help(Text("New Template", bundle: .module))
        .accessibilityLabel(Text("New Template", bundle: .module))
        .disabled(model.isReadOnly)

        Button(action: requestDeleteSelection) {
          Image(systemName: "minus")
        }
        .help(Text(deleteTitle))
        .accessibilityLabel(Text(deleteTitle))
        .disabled(model.isReadOnly || model.editing == nil)

        Menu {
          actionsMenu
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More", bundle: .module))
        .accessibilityLabel(Text("More actions", bundle: .module))
        Spacer()
      }
      .buttonStyle(.borderless)
      .padding(.top, 6)
    }
  }

  private func row(_ template: PromptTemplate) -> some View {
    HStack(spacing: 8) {
      if let appearance = template.appearance {
        SessionBadge(appearance: appearance, size: 18)
      } else {
        Image(systemName: "text.badge.plus")
          .foregroundStyle(.secondary)
          .frame(width: 18)
      }
      Text(template.trimmedName)
        .lineLimit(1)
    }
    .tag(Optional(template.id))
    .contextMenu { templateActions(for: template) }
  }

  @ViewBuilder
  private var actionsMenu: some View {
    if let selected = model.savedEditing {
      templateActions(for: selected)
      Divider()
    }
    Button(LocalizedStringResource("Add Examples", bundle: .module)) {
      Task { await model.addExamples() }
    }
    .disabled(!model.canAddExamples)
    Divider()
    Button(LocalizedStringResource("Import…", bundle: .module)) { isImporting = true }
      .disabled(model.isReadOnly || !model.canExchange)
    Button(LocalizedStringResource("Export All…", bundle: .module)) { requestExport(ids: nil) }
      .disabled(model.all.isEmpty || !model.canExchange)
  }

  @ViewBuilder
  private func templateActions(for template: PromptTemplate) -> some View {
    Button(LocalizedStringResource("Duplicate", bundle: .module)) {
      Task { await model.duplicate(template.id) }
    }
    .disabled(model.isReadOnly)
    Button(LocalizedStringResource("Move Up", bundle: .module)) {
      Task { await model.move(template.id, by: -1) }
    }
    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
    .disabled(!model.canMove(template.id, by: -1))
    Button(LocalizedStringResource("Move Down", bundle: .module)) {
      Task { await model.move(template.id, by: 1) }
    }
    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
    .disabled(!model.canMove(template.id, by: 1))
    Button(LocalizedStringResource("Delete…", bundle: .module), role: .destructive) {
      pendingDelete = template
    }
    .disabled(model.isReadOnly)
    Button(LocalizedStringResource("Export “\(template.trimmedName)”…", bundle: .module)) {
      requestExport(ids: [template.id])
    }
    .disabled(!model.canExchange)
  }

  // MARK: - The editor

  @ViewBuilder
  private var detail: some View {
    VStack(spacing: 0) {
      if let editing = model.editing {
        editor(editing)
      } else if model.all.isEmpty && model.state == .ready {
        emptyLibrary
      } else {
        Text(
          model.state == .loading
            ? LocalizedStringResource("Loading templates…", bundle: .module)
            : LocalizedStringResource("Select a template.", bundle: .module)
        )
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
          Button(LocalizedStringResource("Reveal in Finder", bundle: .module)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
      }
    }
    if let failure = model.failure {
      Banner(symbol: "exclamationmark.triangle", text: failure) {
        Button(LocalizedStringResource("Dismiss", bundle: .module)) { model.dismissFailure() }
      }
    }
    if let summary = model.importSummary {
      Banner(symbol: "checkmark.circle", text: summary) {
        Button(LocalizedStringResource("Dismiss", bundle: .module)) { model.dismissImportSummary() }
      }
    }
  }

  private var emptyLibrary: some View {
    VStack(spacing: 12) {
      Text("No templates yet.", bundle: .module)
        .font(.title3)
      Text(
        "A template is a prompt with fields to fill in — “Review {{url}}” — ready to start a session from.",
        bundle: .module
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 360)
      HStack {
        Button(LocalizedStringResource("Add Examples", bundle: .module)) {
          Task { await model.addExamples() }
        }
        Button(LocalizedStringResource("New Template", bundle: .module)) {
          model.newTemplate()
          isNameFocused = true
        }
        .buttonStyle(.borderedProminent)
      }
      .disabled(model.isReadOnly)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The template being written in the middle, and on the right what it gives: a value to try per
  /// field, what the patterns keep of it, and the session and prompt made with those values.
  private func editor(_ editing: PromptTemplate) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            EditorRow(
              LocalizedStringResource(
                "Name", bundle: .module, comment: "The name of a prompt template."),
              issues: issues(for: .name)
            ) {
              TextField(text: binding(\.name)) {
                Text("What is it for?", bundle: .module)
              }
              .textFieldStyle(.roundedBorder)
              .focused($isNameFocused)
            }
            EditorRow(
              LocalizedStringResource("Session name", bundle: .module),
              help: LocalizedStringResource(
                "Optional — names the sessions made from it, with the same {{fields}}.",
                bundle: .module),
              issues: issues(for: .sessionName)
            ) {
              TextField(text: binding(\.sessionNamePattern)) {
                Text(
                  "Review {{url}}", bundle: .module,
                  comment: "An example of a session name pattern. Keep {{url}} as it is.")
              }
              .textFieldStyle(.roundedBorder)
              .font(.body.monospaced())
            }
            EditorRow(
              LocalizedStringResource("Folder", bundle: .module),
              help: LocalizedStringResource(
                "Optional — proposed as the working folder when this template is picked.",
                bundle: .module),
              issues: issues(for: .folder)
            ) {
              HStack(spacing: 8) {
                TextField(
                  text: Binding(
                    get: { model.editing?.workingDirectoryPath ?? "" },
                    set: { model.editing?.workingDirectoryPath = $0.isEmpty ? nil : $0 }
                  )
                ) {
                  Text(
                    "None — the sheet keeps its folder", bundle: .module,
                    comment:
                      "Placeholder of a template's folder: the New Session sheet keeps its own.")
                }
                .textFieldStyle(.roundedBorder)
                Button(LocalizedStringResource("Choose…", bundle: .module), action: chooseFolder)
                if model.editing?.folder != nil {
                  Button {
                    model.editing?.workingDirectoryPath = nil
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                  }
                  .buttonStyle(.borderless)
                  .foregroundStyle(.secondary)
                  .help(Text("No folder", bundle: .module))
                  .accessibilityLabel(Text("Remove the folder", bundle: .module))
                }
              }
            }
            EditorRow(
              LocalizedStringResource("Appearance", bundle: .module),
              help: editing.appearance == nil
                ? LocalizedStringResource(
                  "Optional — the symbol and colour of the sessions made from it.", bundle: .module)
                : nil,
              issues: issues(for: .appearance)
            ) {
              appearancePicker(editing)
            }
            EditorRow(
              LocalizedStringResource("Prompt", bundle: .module),
              help: LocalizedStringResource(
                "{{name}} is a field, {{name?}} an optional one, {{name|/regex/}} keeps part of it. Write \\{{ to keep the braces as text.",
                bundle: .module,
                comment: "Keep {{name}}, {{name?}}, {{name|/regex/}} and \\{{ as they are."),
              issues: issues(for: .body)
            ) {
              VStack(alignment: .leading, spacing: 5) {
                PromptTextEditor(
                  text: binding(\.body),
                  accessibilityLabel: String(localized: "Prompt", bundle: .module),
                  highlightsPlaceholders: true,
                  isEditable: !model.isReadOnly
                )
                // A text view of its own per template, so ⌘Z never brings back another one's text.
                .id(editing.id)
                malformedNotice(editing)
              }
            }
            fieldsTable(editing)
          }
          .padding(.horizontal, 4)
          .padding(.bottom, 12)
          .disabled(model.isReadOnly)
        }
        .frame(minWidth: 420, maxWidth: .infinity)

        tryColumn(editing)
          .frame(width: 300)
      }
      footer(editing)
    }
  }

  @ViewBuilder
  private func malformedNotice(_ editing: PromptTemplate) -> some View {
    let parsed = PromptTemplateSyntax.parse(editing.body)
    if let first = parsed.malformed.first {
      let text = String(
        decoding: Array(editing.body.utf16)[first], as: UTF16.self)
      Text(
        "\(text) is not a field — names use letters, digits, - and _ — so it stays as text.",
        bundle: .module, comment: "What the user wrote between double braces."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// One row per field, as the text first reads them: what the form calls it, the hint inside the
  /// empty control, and its two switches.
  @ViewBuilder
  private func fieldsTable(_ editing: PromptTemplate) -> some View {
    let fields = editing.fields
    EditorRow(
      LocalizedStringResource("Fields", bundle: .module),
      help: fields.isEmpty
        ? LocalizedStringResource(
          "Fields appear here as you write {{name}} in the text.", bundle: .module)
        : nil,
      issues: []
    ) {
      if !fields.isEmpty {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
          GridRow {
            Text("Field", bundle: .module)
            Text("Label", bundle: .module)
            Text("Hint", bundle: .module)
            Text("Required", bundle: .module).gridColumnAlignment(.center)
            Text("Multiline", bundle: .module).gridColumnAlignment(.center)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          Divider()
          ForEach(fields) { field in
            GridRow {
              Text(field.name)
                .font(.callout.monospaced().weight(.semibold))
                .lineLimit(1)
                .frame(minWidth: 60, alignment: .leading)
              TextField(
                PromptTemplateField.derivedLabel(for: field.name),
                text: settingsBinding(field.name, \.label)
              )
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel(
                Text("Label of \(field.name)", bundle: .module, comment: "A field's name."))
              TextField(text: settingsBinding(field.name, \.help)) {
                Text("Hint", bundle: .module)
              }
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel(
                Text("Hint of \(field.name)", bundle: .module, comment: "A field's name."))
              Toggle(
                LocalizedStringResource("Required", bundle: .module),
                isOn: Binding(
                  get: { field.isRequired },
                  set: { model.setRequired($0, for: field.name) }
                )
              )
              .labelsHidden()
              .accessibilityLabel(
                Text("\(field.name) is required", bundle: .module, comment: "A field's name."))
              Toggle(
                LocalizedStringResource("Multiline", bundle: .module),
                isOn: Binding(
                  get: { field.isMultiline },
                  set: { value in model.updateSettings(for: field.name) { $0.isMultiline = value } }
                )
              )
              .labelsHidden()
              .accessibilityLabel(
                Text("\(field.name) is multiline", bundle: .module, comment: "A field's name."))
            }
          }
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
      }
    }
  }

  /// A value to try per field — shared by the patterns and the preview, never saved — and what
  /// the template gives with them.
  private func tryColumn(_ editing: PromptTemplate) -> some View {
    let fill = PromptTemplateFill(template: editing, values: model.sampleValues)
    return ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Try it", bundle: .module)
          .font(.headline)
        if editing.fields.isEmpty {
          Text("Values to try appear here for each field of the template.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(editing.fields) { field in
          VStack(alignment: .leading, spacing: 5) {
            Text(field.label)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            let value = Binding(
              get: { model.sampleValues[field.name] ?? "" },
              set: { model.sampleValues[field.name] = $0 }
            )
            if field.isMultiline {
              PromptTextEditor(
                text: value, minimumLines: 2, placeholder: field.help,
                accessibilityLabel: String(
                  localized: "Value to try for \(field.label)", bundle: .module,
                  comment: "A field's label."))
            } else {
              TextField(
                field.help ?? String(localized: "A value to try", bundle: .module), text: value
              )
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel(
                Text(
                  "Value to try for \(field.label)", bundle: .module,
                  comment: "A field's label."))
            }
            ExtractionResultsView(results: fill.extractions(for: field.name), showsPlaces: true)
          }
        }
        if let preview = model.preview {
          Divider()
          Text("Preview", bundle: .module)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          if let name = preview.sessionName, !name.isEmpty {
            Text(
              "Session \(Text(name).bold())", bundle: .module,
              comment: "The name of the session the template would give, in bold."
            )
            .font(.callout)
            .textSelection(.enabled)
          }
          PromptPreviewText(rendered: preview)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
            }
          Text(
            "\(PromptSize.label(preview.byteCount)) of \(PromptSize.label(AgentPromptLimits.argumentByteLimit))",
            bundle: .module,
            comment: "The size of the prompt, then the most an agent accepts: “1.2 KB of 128 KB”."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Bounded by its shape, so it stays in the column rather than reaching under the tabs.
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor))
    }
  }

  private func footer(_ editing: PromptTemplate) -> some View {
    HStack {
      if model.isEdited {
        Text(
          model.isNew
            ? LocalizedStringResource("Not saved yet", bundle: .module)
            : LocalizedStringResource(
              "Edited", bundle: .module, comment: "The prompt template has unsaved changes.")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let saved = model.savedEditing {
        Text(
          "Revision \(String(saved.revision))", bundle: .module,
          comment: "The number of times the prompt template was saved."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button(LocalizedStringResource("Revert", bundle: .module)) { model.revert() }
        .disabled(!model.isEdited)
      Button(LocalizedStringResource("Save", bundle: .module)) { Task { await model.save() } }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSave)
        .background {
          Button(LocalizedStringResource("Save", bundle: .module)) {
            Task { await model.save() }
          }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!model.canSave)
          .hidden()
        }
    }
    .padding(.top, 12)
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

  /// The symbols and colours the New Session sheet offers, and None to leave the sessions their
  /// own. Picking one of the two when there is none yet starts from the template's name.
  private func appearancePicker(_ editing: PromptTemplate) -> some View {
    let current = editing.appearance
    let base = current ?? SessionAppearanceCatalog.derived(forName: editing.trimmedName)
    return HStack(alignment: .top, spacing: 14) {
      SessionBadge(appearance: current ?? SessionAppearanceCatalog.placeholder, size: 40)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          ForEach(SessionAppearanceCatalog.symbolNames, id: \.self) { symbol in
            SymbolChoice(
              symbol: symbol,
              isSelected: current?.symbolName == symbol,
              select: {
                model.editing?.appearance = SessionAppearance(
                  symbolName: symbol, colorHex: base.colorHex)
              }
            )
          }
        }
        HStack(spacing: 6) {
          ForEach(SessionAppearanceCatalog.colorHexValues, id: \.self) { hex in
            ColorChoice(
              hex: hex,
              isSelected: current?.colorHex == hex,
              select: {
                model.editing?.appearance = SessionAppearance(
                  symbolName: base.symbolName, colorHex: hex)
              }
            )
          }
          if current != nil {
            Button(LocalizedStringResource("None", bundle: .module)) {
              model.editing?.appearance = nil
            }
            .controlSize(.small)
            .help(Text("Sessions made from it keep their own symbol and colour.", bundle: .module))
          }
        }
      }
    }
  }

  private var deleteTitle: LocalizedStringResource {
    model.isNew
      ? LocalizedStringResource("Discard This Template", bundle: .module)
      : LocalizedStringResource("Delete Template", bundle: .module)
  }

  private static var untitledName: String {
    String(
      localized: "Untitled Template", bundle: .module,
      comment: "The name of a new prompt template, until the user names it.")
  }

  private static var exportName: String {
    String(
      localized: "Prompt Templates", bundle: .module,
      comment: "The name of the file prompt templates are exported to.")
  }

  /// Written with a `~` when it is in the home folder, so an exported template means the same
  /// folder on another Mac.
  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = String(
      localized: "Choose", bundle: .module, comment: "The button of the folder panel.")
    let current = model.editing?.folder.map { ($0 as NSString).expandingTildeInPath }
    panel.directoryURL = URL(fileURLWithPath: current ?? NSHomeDirectory(), isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.editing?.workingDirectoryPath = (url.path as NSString).abbreviatingWithTildeInPath
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
    var name = Self.exportName
    if let ids, ids.count == 1, let id = ids.first {
      name =
        model.library.template(id: id)?.trimmedName
        ?? String(
          localized: "Prompt Template", bundle: .module,
          comment: "The name of the file one prompt template is exported to.")
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
      Text("Import Templates", bundle: .module)
        .font(.title2.weight(.semibold))
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 10)
      Divider()
      if let plan = model.pendingImport?.plan {
        List(plan.entries) { entry in
          HStack(alignment: .firstTextBaseline) {
            Text(
              entry.template.trimmedName.isEmpty
                ? String(
                  localized: "Untitled", bundle: .module,
                  comment: "An imported prompt template that has no name.")
                : entry.template.trimmedName
            )
            .lineLimit(1)
            Spacer()
            outcome(entry)
          }
        }
        .frame(minHeight: 220)
      }
      Divider()
      HStack {
        Text("Nothing is replaced unless you choose it.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
          model.cancelImport()
        }
        .keyboardShortcut(.cancelAction)
        Button(LocalizedStringResource("Import", bundle: .module)) {
          Task { await model.applyImport() }
        }
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
      Text(
        "New", bundle: .module, comment: "An imported template the library does not have yet."
      ).foregroundStyle(.secondary)
    case .identical:
      Text(
        "Identical — skipped", bundle: .module,
        comment: "An imported template the library already has as it is."
      ).foregroundStyle(.secondary)
    case .skipped(let reason):
      Text(
        "Skipped: \(reason)", bundle: .module,
        comment: "Why an imported template is left out."
      )
      .foregroundStyle(.orange)
      .font(.caption)
      .lineLimit(2)
    case .changed:
      Picker(
        LocalizedStringResource(
          "Changed", bundle: .module,
          comment: "An imported template that differs from the one of the library."),
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
        Text("Keep Both", bundle: .module).tag(false)
        Text("Replace", bundle: .module, comment: "Replace the template of the library.").tag(true)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .accessibilityLabel(
        Text(
          "\(entry.template.trimmedName) changed", bundle: .module,
          comment: "The name of an imported template that differs from the library's."))
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
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .padding([.horizontal, .top], 16)
  }
}

private struct EditorRow<Content: View>: View {
  private let title: LocalizedStringResource
  private let help: LocalizedStringResource?
  private let issues: [PromptTemplateIssue]
  private let content: Content

  init(
    _ title: LocalizedStringResource, help: LocalizedStringResource? = nil,
    issues: [PromptTemplateIssue],
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.issues = issues
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
      ForEach(issues) { issue in
        Label {
          Text(verbatim: "\(issue.message) \(issue.remedy)")
        } icon: {
          Image(systemName: "exclamationmark.circle.fill")
        }
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
