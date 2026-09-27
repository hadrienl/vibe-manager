import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// The Tickets tab of the settings (#89): whether ticket titles go to the notes, in what line, the
/// resolvers that recognise a ticket's address, and a test of an address.
struct TicketSettingsView: View {
  @Bindable var model: TicketTitlesModel
  @State private var selectedID: UUID?
  @State private var draft: TicketResolver?
  @State private var formatText = ""
  @State private var isImporting = false
  @State private var exportData: Data?
  @State private var importReport: String?
  @State private var testAddress = ""
  @State private var testResult: TicketTitlesModel.TestResult?
  @State private var isTesting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      general
      Divider()
      HStack(alignment: .top, spacing: 16) {
        sidebar
          .frame(width: 220)
        editor
          .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      Divider()
      tester
    }
    .padding(16)
    .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 680)
    .task {
      await model.load()
      formatText = model.lineFormat.template
      if selectedID == nil { select(model.resolvers.first?.id) }
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
      guard case .success(let url) = result else { return }
      Task { await importFile(at: url) }
    }
    .fileExporter(
      isPresented: Binding(get: { exportData != nil }, set: { if !$0 { exportData = nil } }),
      document: exportData.map(ResolverFile.init(data:)),
      contentType: .json,
      defaultFilename: "Ticket Resolvers.json"
    ) { _ in
      exportData = nil
    }
    .alert(
      Text("Import", bundle: .module, comment: "The title of the report of an import."),
      isPresented: Binding(get: { importReport != nil }, set: { if !$0 { importReport = nil } })
    ) {
      Button {
        importReport = nil
      } label: {
        Text("OK", bundle: .module)
      }
    } message: {
      Text(importReport ?? "")
    }
  }

  // MARK: - The switch and the format

  private var general: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: $model.insertsTicketTitles) {
        Text("Insert ticket titles in the notes", bundle: .module)
      }
      Text(
        """
        When a new session names a ticket's address, its page opens in the session's web view, \
        where you are signed in, and its title goes to the top of the notes. Only addresses a \
        resolver below recognises are opened.
        """,
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .firstTextBaseline) {
        Text("Line format", bundle: .module)
        TextField(text: $formatText, prompt: Text(verbatim: TicketLineFormat.standard.template)) {
          Text("Line format", bundle: .module)
        }
        .font(.body.monospaced())
        .onChange(of: formatText) { _, text in
          let format = TicketLineFormat(text)
          if format.isValid { model.lineFormat = format }
        }
      }
      if TicketLineFormat(formatText).isValid {
        Text(
          "Example: \(TicketLineFormat(formatText).line(id: "acme/app#42", title: String(localized: "Allow exporting as CSV", bundle: .module), url: "https://github.com/acme/app/issues/42"))",
          bundle: .module, comment: "A line as it would be written in the notes."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        Text(
          "The format must hold {title}, and may hold {id} and {url}.", bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
      if let error = model.storeError {
        HStack {
          Text(error)
            .font(.caption)
            .foregroundStyle(.orange)
          if let url = model.fileURL {
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
              Text("Reveal in Finder", bundle: .module)
            }
            .buttonStyle(.link)
            .font(.caption)
          }
        }
      }
    }
    .disabled(!model.isLoaded)
  }

  // MARK: - The list

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: Binding(get: { selectedID }, set: { select($0) })) {
        ForEach(model.resolvers) { resolver in
          HStack {
            Toggle(isOn: enabledBinding(resolver.id)) {
              Text(verbatim: resolver.trimmedName)
            }
            .toggleStyle(.checkbox)
            Spacer()
          }
          .tag(Optional(resolver.id))
        }
        .onMove { source, destination in
          var list = model.resolvers
          list.move(fromOffsets: source, toOffset: destination)
          Task { await model.save(list) }
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: false))
      HStack(spacing: 4) {
        Button {
          add()
        } label: {
          Image(systemName: "plus")
        }
        .help(Text("Add a resolver", bundle: .module))
        Button {
          duplicate()
        } label: {
          Image(systemName: "plus.square.on.square")
        }
        .disabled(selectedID == nil)
        .help(Text("Duplicate the resolver", bundle: .module))
        Button {
          remove()
        } label: {
          Image(systemName: "minus")
        }
        .disabled(selectedID == nil)
        .help(Text("Delete the resolver", bundle: .module))
        Spacer()
        Menu {
          Button {
            isImporting = true
          } label: {
            Text("Import…", bundle: .module)
          }
          Button {
            exportData = try? TicketResolverExchange.encode(model.resolvers, exportedAt: Date())
          } label: {
            Text("Export…", bundle: .module)
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
      }
      .buttonStyle(.borderless)
      .padding(.top, 6)
    }
  }

  private func enabledBinding(_ id: UUID) -> Binding<Bool> {
    Binding(
      get: { model.resolvers.first { $0.id == id }?.isEnabled ?? false },
      set: { value in
        var list = model.resolvers
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].isEnabled = value
        if draft?.id == id { draft?.isEnabled = value }
        Task { await model.save(list) }
      })
  }

  // MARK: - The editor

  @ViewBuilder
  private var editor: some View {
    if let draft {
      let binding = Binding(get: { self.draft ?? draft }, set: { self.draft = $0 })
      let issues = binding.wrappedValue.validate()
      Form {
        TextField(text: binding.name, prompt: Text(verbatim: "Redmine")) {
          Text("Name", bundle: .module)
        }
        TextField(
          text: binding.pattern,
          prompt: Text(verbatim: #"https://redmine\.acme\.fr/issues/(?<number>[0-9]+)"#)
        ) {
          Text("Address pattern", bundle: .module)
          Text(
            "A regular expression, with named captures such as (?<number>[0-9]+).",
            bundle: .module)
        }
        .font(.body.monospaced())
        TextField(text: binding.shortID, prompt: Text(verbatim: "#{number}")) {
          Text("Identifier", bundle: .module)
          Text("Shown before the title: the captures in braces, and {host}.", bundle: .module)
        }
        .font(.body.monospaced())
        Section {
          ForEach(binding.titleCleanup.indices, id: \.self) { index in
            HStack {
              TextField(text: binding.titleCleanup[index], prompt: Text(verbatim: " - Redmine$")) {
                Text("Rule \(index + 1)", bundle: .module, comment: "A rule's position.")
              }
              .labelsHidden()
              .font(.body.monospaced())
              Button {
                self.draft?.titleCleanup.remove(at: index)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help(Text("Remove the rule", bundle: .module))
            }
          }
          Button {
            self.draft?.titleCleanup.append("")
          } label: {
            Text("Add a Rule", bundle: .module)
          }
        } header: {
          Text("Title cleanup", bundle: .module)
        } footer: {
          Text(
            "Regular expressions whose matches are removed from the page's title, in this order.",
            bundle: .module)
        }
        if !issues.isEmpty {
          Section {
            ForEach(issues, id: \.self) { issue in
              Text(Self.sentence(issue))
                .foregroundStyle(.orange)
            }
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        if let origin = draft.preset,
          TicketResolverPresets.shipped(id: origin.id).map({
            !binding.wrappedValue.sameRules(as: $0)
          })
            == true
        {
          Button {
            self.draft = TicketResolverPresets.restoring(binding.wrappedValue)
          } label: {
            Text("Restore the Shipped Version", bundle: .module)
          }
        }
        Spacer()
        Button {
          self.draft = model.resolvers.first { $0.id == draft.id }
        } label: {
          Text("Revert", bundle: .module)
        }
        .disabled(!isDirty)
        Button {
          Task { await saveDraft() }
        } label: {
          Text("Save", bundle: .module)
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!isDirty || !issues.isEmpty)
      }
      .padding(.horizontal, 20)
    } else {
      ContentUnavailableView {
        Label {
          Text("No resolver selected", bundle: .module)
        } icon: {
          Image(systemName: "link")
        }
      }
    }
  }

  private var isDirty: Bool {
    guard let draft else { return false }
    return model.resolvers.first { $0.id == draft.id } != draft
  }

  private func select(_ id: UUID?) {
    // A change that can be kept is kept: the list is not a place where edits are lost.
    if isDirty, let draft, draft.validate().isEmpty {
      Task { await saveDraft(draft) }
    }
    selectedID = id
    draft = id.flatMap { id in model.resolvers.first { $0.id == id } }
  }

  private func saveDraft(_ resolver: TicketResolver? = nil) async {
    guard let resolver = resolver ?? draft else { return }
    var list = model.resolvers
    if let index = list.firstIndex(where: { $0.id == resolver.id }) {
      list[index] = resolver
    } else {
      list.append(resolver)
    }
    if await model.save(list), draft?.id == resolver.id {
      draft = model.resolvers.first { $0.id == resolver.id }
    }
  }

  private func add() {
    let resolver = TicketResolver(
      name: TicketResolverExchange.uniqueName(
        String(localized: "New Resolver", bundle: .module),
        among: model.resolvers.map(\.trimmedName)),
      pattern: "", shortID: "")
    selectedID = resolver.id
    draft = resolver
  }

  private func duplicate() {
    guard let source = draft ?? model.resolvers.first(where: { $0.id == selectedID }) else {
      return
    }
    var copy = source
    copy.id = UUID()
    copy.preset = nil
    copy.name = TicketResolverExchange.uniqueName(
      source.trimmedName, among: model.resolvers.map(\.trimmedName))
    Task {
      await saveDraft(copy)
      select(copy.id)
    }
  }

  private func remove() {
    guard let selectedID else { return }
    let list = model.resolvers.filter { $0.id != selectedID }
    draft = nil
    self.selectedID = nil
    Task {
      await model.save(list)
      select(model.resolvers.first?.id)
    }
  }

  private func importFile(at url: URL) async {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do {
      let decoded = try TicketResolverExchange.decode(try Data(contentsOf: url))
      let merged = TicketResolverExchange.merge(decoded.resolvers, into: model.resolvers)
      guard await model.save(merged) else { return }
      importReport = Self.importSentence(
        imported: decoded.resolvers.count, skipped: decoded.skipped)
    } catch {
      importReport = String(
        localized: "This file is not a file of ticket resolvers that Vibe Manager can read.",
        bundle: .module)
    }
  }

  static func importSentence(imported: Int, skipped: Int) -> String {
    let done = String(
      localized: "\(imported) resolvers imported.", bundle: .module,
      comment: "How many ticket resolvers an import added or replaced.")
    guard skipped > 0 else { return done }
    return done + " "
      + String(
        localized: "\(skipped) resolvers left out: they are not valid.", bundle: .module,
        comment: "How many ticket resolvers of a file could not be imported.")
  }

  // MARK: - The test

  private var tester: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField(
          text: $testAddress, prompt: Text(verbatim: "https://github.com/acme/app/issues/42")
        ) {
          Text("Test with an address", bundle: .module)
        }
        .onSubmit(test)
        Button(action: test) {
          Text("Test", bundle: .module)
        }
        .disabled(testAddress.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
      }
      if isTesting {
        ProgressView().controlSize(.small)
      } else if let testResult {
        TicketTestResultView(result: testResult)
      }
    }
  }

  private func test() {
    var resolvers = model.resolvers
    // What is being edited is what the user wants to try.
    if let draft, draft.validate().isEmpty {
      if let index = resolvers.firstIndex(where: { $0.id == draft.id }) {
        resolvers[index] = draft
      } else {
        resolvers.append(draft)
      }
    }
    isTesting = true
    let address = testAddress
    Task {
      testResult = await model.test(address, with: resolvers)
      isTesting = false
    }
  }

  static func sentence(_ issue: TicketResolverIssue) -> String {
    switch issue {
    case .nameMissing:
      return String(localized: "Give the resolver a name.", bundle: .module)
    case .patternMissing:
      return String(localized: "Write the pattern of the addresses it recognises.", bundle: .module)
    case .patternInvalid:
      return String(localized: "The pattern is not a valid regular expression.", bundle: .module)
    case .patternWithoutCaptures:
      return String(
        localized: "The pattern needs at least one named capture, such as (?<number>[0-9]+).",
        bundle: .module)
    case .shortIDMissing:
      return String(localized: "Write the identifier shown before the title.", bundle: .module)
    case .unknownPlaceholder(let name):
      return String(
        localized: "{\(name)} is not a capture of the pattern.", bundle: .module,
        comment: "The name of a placeholder written in braces.")
    case .cleanupInvalid(let index):
      return String(
        localized: "Rule \(index + 1) is not a valid regular expression.", bundle: .module,
        comment: "A rule's position.")
    }
  }
}

/// What a test of an address gave: which resolver recognised it, what it captured, and the line.
private struct TicketTestResultView: View {
  let result: TicketTitlesModel.TestResult

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      switch result {
      case .notRecognized:
        Text(
          "No resolver recognises this address: nothing would be loaded.", bundle: .module
        )
        .foregroundStyle(.secondary)
      case .recognized(let ticket, let name, let outcome, let line):
        Label {
          Text(
            "Recognised by \(name): \(ticket.shortID)", bundle: .module,
            comment: "A resolver's name, then the ticket's identifier.")
        } icon: {
          Image(systemName: "checkmark.circle")
        }
        Text(
          verbatim: ticket.captures.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        if let outcome {
          outcomeView(outcome, ticket: ticket)
        }
        if let line {
          Text(verbatim: "→ \(line)")
            .textSelection(.enabled)
        }
      }
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func outcomeView(_ outcome: TicketPageOutcome, ticket: TicketRecognition) -> some View {
    switch outcome {
    case .title(_, let raw):
      Text("Title of the page: “\(raw)”", bundle: .module, comment: "The raw title of a page.")
        .foregroundStyle(.secondary)
    case .signInRequired(let host):
      Text(
        "\(host) asks to sign in: sign in in a session's web view, then test again.",
        bundle: .module, comment: "A site."
      )
      .foregroundStyle(.orange)
    case .notFound(let status):
      Text(
        "The page answered \(String(status)): the ticket was not found, or is not visible to the account signed in.",
        bundle: .module, comment: "An HTTP status: “404”."
      )
      .foregroundStyle(.orange)
    case .failed(let failure):
      Text(TicketTitlesPresentation.failed(failure, id: ticket.shortID))
        .foregroundStyle(.orange)
    case .abandoned:
      EmptyView()
    }
  }
}

private struct ResolverFile: FileDocument {
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
