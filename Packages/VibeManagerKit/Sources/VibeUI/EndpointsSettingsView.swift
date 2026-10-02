import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// An endpoint's page of the settings (#107, #313): a model server a session can run on, driven
/// by Claude Code or Codex through the gateway. Without an endpoint, the page of a new one: the
/// server it starts from, then the same form.
struct EndpointsSettingsView: View {
  @Bindable var model: EndpointsSettingsModel
  /// The endpoint shown; `nil` for a new one.
  let endpointID: EndpointID?
  /// Turns the settings to another page: the endpoint just added, duplicated, or the one after
  /// the endpoint deleted.
  let show: (SettingsPage) -> Void
  @State private var draft: Endpoint?
  /// The server a new endpoint starts from. Its protocol is then the server's, and only "Other
  /// Server" asks for one.
  @State private var preset: EndpointsSettingsModel.Preset?
  /// The key typed in the form. Written to the keychain on Save, never kept elsewhere.
  @State private var typedSecret = ""
  @State private var secretError: String?
  @State private var newModelID = ""
  @State private var isDiscovering = false
  @State private var discoveryError: EndpointDiscoveryError?
  @State private var testedModel: String?
  @State private var isTesting = false
  @State private var report: EndpointTestReport?
  @State private var showsAdvanced = false
  @State private var isConfirmingDelete = false

  init(
    model: EndpointsSettingsModel, endpointID: EndpointID?,
    show: @escaping (SettingsPage) -> Void
  ) {
    self.model = model
    self.endpointID = endpointID
    self.show = show
  }

  private var isNew: Bool { endpointID == nil }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        if let error = model.storeError {
          storeProblem(error)
        }
        if isNew {
          starts
        }
        editor
      }
      .formStyle(.grouped)
      if let draft {
        footer(
          Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }),
          issues: (self.draft ?? draft).validationIssues)
      }
    }
    .task {
      await model.load()
      if !isNew, draft == nil {
        draft = model.endpoints.first { $0.id == endpointID }
      }
    }
    // Leaving the page keeps what was typed, as leaving a row of the list did.
    .onDisappear { saveOnLeaving() }
    .confirmationDialog(
      Text(
        "Delete “\(draft?.name ?? "")” and its key?", bundle: .module,
        comment: "The name of an endpoint."),
      isPresented: $isConfirmingDelete
    ) {
      Button(role: .destructive) {
        remove()
      } label: {
        Text("Delete", bundle: .module)
      }
    } message: {
      Text("Sessions that run on it keep it until they are restarted.", bundle: .module)
    }
  }

  private func storeProblem(_ error: String) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
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

  /// What an endpoint is, and the servers a new one starts from.
  private var starts: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          """
          An endpoint is a model server reachable over HTTP, on this Mac or in the cloud. Its models \
          then appear beside Claude Code and Codex when you create a session, driven by one of them.
          """,
          bundle: .module
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
          ForEach(EndpointsSettingsModel.presets) { preset in
            presetCard(preset)
          }
        }
      }
      .padding(.vertical, 4)
    } header: {
      Text("Work with any model", bundle: .module)
    }
  }

  private func presetCard(_ preset: EndpointsSettingsModel.Preset) -> some View {
    let isChosen = self.preset?.id == preset.id
    return Button {
      start(from: preset)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.presetName(preset))
          .fontWeight(.medium)
        Text(Self.presetDetail(preset))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        if isChosen {
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }

  // MARK: - The editor

  @ViewBuilder
  private var editor: some View {
    if let draft {
      let binding = Binding(get: { self.draft ?? draft }, set: { self.draft = $0 })
      connection(binding)
      harness(binding)
      models(binding)
      advanced(binding)
      test(binding)
    }
  }

  private func connection(_ binding: Binding<Endpoint>) -> some View {
    Section {
      TextField(text: binding.name, prompt: Text(verbatim: "OpenRouter")) {
        Text("Name", bundle: .module)
      }
      // The value in a fixed-width font, not its label.
      LabeledContent {
        TextField(text: binding.baseURL, prompt: Text(verbatim: "https://openrouter.ai/api/v1")) {
          Text("Base URL", bundle: .module)
        }
        .labelsHidden()
        .font(.body.monospaced())
      } label: {
        Text("Base URL", bundle: .module)
      }
      if isNew, let preset, preset.id != EndpointsSettingsModel.otherPresetID {
        // The server's own: asked only of another server, and changed once the endpoint is added.
        LabeledContent {
          Text(verbatim: Self.protocolName(binding.wrappedValue.wireProtocol))
        } label: {
          Text("Protocol", bundle: .module)
          Text(
            "The one \(Self.presetName(preset)) speaks. It can be changed once the endpoint is added.",
            bundle: .module, comment: "The name of a model server, such as Ollama.")
        }
      } else {
        Picker(selection: binding.wireProtocol) {
          ForEach(EndpointWireKind.allCases, id: \.self) { wire in
            Text(Self.protocolName(wire)).tag(wire)
          }
        } label: {
          Text("Protocol", bundle: .module)
          if isNew {
            Text(
              "What the server speaks. Its documentation often says “OpenAI-compatible” or “Anthropic-compatible”.",
              bundle: .module)
          }
        }
      }
      Picker(selection: authenticationKind(binding)) {
        Text("None", bundle: .module, comment: "No authentication.").tag(AuthenticationKind.none)
        Text("Bearer token", bundle: .module).tag(AuthenticationKind.bearer)
        Text("Header", bundle: .module, comment: "A key sent in a header of its own.")
          .tag(AuthenticationKind.header)
        Text("Query parameter", bundle: .module).tag(AuthenticationKind.query)
      } label: {
        Text("Authentication", bundle: .module)
      }
      switch binding.wrappedValue.authentication {
      case .header, .query:
        LabeledContent {
          TextField(text: authenticationName(binding), prompt: Text(verbatim: "x-api-key")) {
            Text(
              "Name", bundle: .module, comment: "The name of the header or parameter of the key.")
          }
          .labelsHidden()
          .font(.body.monospaced())
        } label: {
          Text("Name", bundle: .module, comment: "The name of the header or parameter of the key.")
        }
      case .none, .bearer:
        EmptyView()
      }
      if binding.wrappedValue.authentication.needsSecret {
        LabeledContent {
          HStack {
            SecureField(text: $typedSecret, prompt: Text(verbatim: "sk-…")) {
              Text("Key", bundle: .module)
            }
            .labelsHidden()
            .frame(minWidth: 180)
            if model.hasSecret(for: binding.wrappedValue.id) {
              Label {
                Text("In the keychain", bundle: .module)
              } icon: {
                Image(systemName: "lock.fill")
              }
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize()
              Button {
                model.removeSecret(for: binding.wrappedValue.id)
              } label: {
                Image(systemName: "xmark.circle")
              }
              .buttonStyle(.borderless)
              .help(Text("Remove the key from the keychain", bundle: .module))
            }
          }
        } label: {
          Text("Key", bundle: .module)
          Text(
            "Kept in the keychain, never shown again. Type a new one to replace it.",
            bundle: .module)
        }
        if let secretError {
          Text(secretError)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      if binding.wrappedValue.wireProtocol == .custom {
        customProtocol(binding)
      }
    } header: {
      Text("Connection", bundle: .module)
    }
  }

  @ViewBuilder
  private func customProtocol(_ binding: Binding<Endpoint>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Protocol document", bundle: .module)
        Spacer()
        Button {
          binding.wrappedValue.customProtocol = EndpointsSettingsModel.customProtocolExample
        } label: {
          Text("Insert the Example", bundle: .module)
        }
        .controlSize(.small)
      }
      TextEditor(text: binding.customProtocol)
        .font(.body.monospaced())
        .frame(height: 180)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
      let text = binding.wrappedValue.customProtocol
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let problem = model.customProtocolProblem(text)
      {
        Text(problem)
          .font(.caption.monospaced())
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      Text(
        """
        How to build a request from the conversation and read the answer: paths into the JSON the \
        endpoint sends, and named values such as {{model}}, {{messages:openai}} or {{lastUserText}}. \
        See docs/endpoints.md.
        """,
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func harness(_ binding: Binding<Endpoint>) -> some View {
    Section {
      LabeledContent {
        Picker(selection: binding.harness) {
          Text(
            "Automatic (\(Self.automaticHarnessName(for: binding.wrappedValue.wireProtocol)))",
            bundle: .module
          )
          .tag(EndpointHarnessChoice.automatic)
          Text(verbatim: "Claude Code").tag(EndpointHarnessChoice.claudeCode)
          Text(verbatim: "Codex").tag(EndpointHarnessChoice.codex)
        } label: {
          Text("Driven by", bundle: .module)
        }
        .labelsHidden()
      } label: {
        Text("Driven by", bundle: .module)
        Text(
          """
          The coding agent that runs the sessions: its tools, its prompts and its permissions. \
          The gateway translates between its protocol and the endpoint's.
          """,
          bundle: .module)
      }
    } header: {
      Text("Agent", bundle: .module)
    }
  }

  private func models(_ binding: Binding<Endpoint>) -> some View {
    Section {
      ForEach(binding.models) { $item in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(verbatim: item.id)
              .font(.body.monospaced())
              .foregroundStyle(item.supportsTools ? .primary : .secondary)
              .textSelection(.enabled)
            Spacer()
            Button {
              self.draft?.models.removeAll { $0.id == item.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("Remove the model", bundle: .module))
          }
          HStack(spacing: 14) {
            Toggle(isOn: $item.supportsTools) {
              Text("Tools", bundle: .module)
            }
            Toggle(isOn: $item.supportsVision) {
              Text("Vision", bundle: .module)
            }
            Toggle(isOn: $item.supportsReasoning) {
              Text("Reasoning", bundle: .module)
            }
            Spacer()
            TextField(
              value: $item.contextWindow, format: .number,
              prompt: Text("Context", bundle: .module)
            ) {
              Text("Context", bundle: .module, comment: "A model's context window, in tokens.")
            }
            .labelsHidden()
            .frame(width: 90)
            .multilineTextAlignment(.trailing)
            .help(Text("The context window, in tokens.", bundle: .module))
          }
          .toggleStyle(.checkbox)
          .font(.callout)
          if !item.supportsTools {
            Text("Cannot call tools: not offered for sessions.", bundle: .module)
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if item.hasShortContext {
            Text(
              "Short for an agent: the harness's prompt and tools already take much of it. Give the model at least \(EndpointModel.minimumAgentContext) tokens on its server.",
              bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 2)
      }
      HStack {
        TextField(text: $newModelID, prompt: Text(verbatim: "qwen3-coder:30b")) {
          Text("Model identifier", bundle: .module)
        }
        .labelsHidden()
        .font(.body.monospaced())
        .onSubmit { addModel() }
        Button {
          addModel()
        } label: {
          Text("Add", bundle: .module)
        }
        .disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if let discoveryError {
        Text(Self.sentence(discoveryError))
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      HStack {
        Text("Models", bundle: .module)
        Spacer()
        Button {
          Task { await discover() }
        } label: {
          if isDiscovering {
            ProgressView().controlSize(.small)
          } else {
            Text("Read from the Endpoint", bundle: .module)
          }
        }
        .disabled(isDiscovering)
      }
    }
  }

  private func advanced(_ binding: Binding<Endpoint>) -> some View {
    Section {
      DisclosureGroup(isExpanded: $showsAdvanced) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Headers", bundle: .module)
            .font(.callout.weight(.medium))
          ForEach(binding.headers.indices, id: \.self) { index in
            HStack {
              TextField(text: binding.headers[index].name, prompt: Text(verbatim: "X-Title")) {
                Text("Header name", bundle: .module)
              }
              .labelsHidden()
              .font(.body.monospaced())
              TextField(text: binding.headers[index].value, prompt: Text(verbatim: "Vibe Manager"))
              {
                Text("Header value", bundle: .module)
              }
              .labelsHidden()
              Button {
                self.draft?.headers.remove(at: index)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help(Text("Remove the header", bundle: .module))
            }
          }
          Button {
            self.draft?.headers.append(EndpointHeader(name: "", value: ""))
          } label: {
            Text("Add a Header", bundle: .module)
          }
          Text("Default parameters", bundle: .module)
            .font(.callout.weight(.medium))
          TextEditor(text: binding.defaultParameters)
            .font(.body.monospaced())
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
          Text(
            "A JSON object merged into every request, such as {\"provider\": {\"sort\": \"throughput\"}}.",
            bundle: .module
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Text("Timeouts, in seconds", bundle: .module)
            .font(.callout.weight(.medium))
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            timeout(Text("First byte", bundle: .module), binding.timeouts.firstByte)
            timeout(
              Text("Silence in an answer", bundle: .module), binding.timeouts.idle)
            timeout(Text("Whole answer", bundle: .module), binding.timeouts.total)
          }
        }
        .padding(.top, 6)
      } label: {
        Text("Advanced", bundle: .module)
      }
    }
  }

  private func timeout(_ label: Text, _ value: Binding<Int>) -> some View {
    GridRow {
      label
      TextField(value: value, format: .number) { label }
        .labelsHidden()
        .frame(width: 70)
        .multilineTextAlignment(.trailing)
    }
  }

  private func test(_ binding: Binding<Endpoint>) -> some View {
    let candidates = binding.wrappedValue.agentModels
    return Section {
      HStack {
        Picker(
          selection: Binding(
            get: { testedModel ?? candidates.first?.id ?? "" },
            set: { testedModel = $0 })
        ) {
          ForEach(candidates) { item in
            Text(verbatim: item.id).tag(item.id)
          }
        } label: {
          Text("Model", bundle: .module)
        }
        .disabled(candidates.isEmpty)
        Button {
          Task { await runTest() }
        } label: {
          if isTesting {
            ProgressView().controlSize(.small)
          } else {
            Text("Test", bundle: .module)
          }
        }
        .disabled(isTesting || candidates.isEmpty)
      }
      if let report {
        ForEach(report.checks) { check in
          EndpointCheckRow(check: check)
        }
      } else if let last = binding.wrappedValue.lastTest {
        Text(Self.lastTestSentence(last))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Test", bundle: .module)
    } footer: {
      Text(
        """
        Sends a short request asking the model to call a tool, then gives it the result: what \
        a session does on every turn. A local model may take a while to load the first time.
        """,
        bundle: .module)
    }
  }

  private func footer(_ binding: Binding<Endpoint>, issues: [EndpointValidationIssue])
    -> some View
  {
    VStack(spacing: 8) {
      if !issues.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(issues, id: \.self) { issue in
            Text(Self.sentence(issue))
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Text(
          "Running sessions keep what they started with until they are restarted.", bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        if isNew {
          Button {
            Task { await add() }
          } label: {
            Text("Add", bundle: .module)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!Self.savable(issues) || hasDocumentProblem(binding.wrappedValue))
        } else {
          Button {
            duplicate()
          } label: {
            Text("Duplicate", bundle: .module)
          }
          Button {
            isConfirmingDelete = true
          } label: {
            Text("Delete…", bundle: .module)
          }
          Button {
            revert()
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
          .disabled(!isDirty || !Self.savable(issues) || hasDocumentProblem(binding.wrappedValue))
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  /// A custom endpoint whose document does not read would fail at its first session.
  private func hasDocumentProblem(_ endpoint: Endpoint) -> Bool {
    endpoint.wireProtocol == .custom && model.customProtocolProblem(endpoint.customProtocol) != nil
  }

  /// An endpoint without a model to run yet can still be saved: its models are read after.
  static func savable(_ issues: [EndpointValidationIssue]) -> Bool {
    issues.allSatisfy { $0 == .noToolModel }
  }

  // MARK: - Actions

  private var isDirty: Bool {
    guard let draft else { return false }
    let typed = !typedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return typed || model.endpoints.first { $0.id == draft.id } != draft
  }

  /// Saved on the way out when it can be: what was typed is not lost by turning the page. A new
  /// endpoint is only added by Add.
  private func saveOnLeaving() {
    guard !isNew, isDirty, let draft, Self.savable(draft.validationIssues),
      !hasDocumentProblem(draft)
    else { return }
    Task { await saveDraft(draft) }
  }

  private func revert() {
    draft = model.endpoints.first { $0.id == draft?.id }
    typedSecret = ""
    secretError = nil
  }

  private func saveDraft(_ endpoint: Endpoint? = nil) async {
    guard var endpoint = endpoint ?? draft else { return }
    if !typedSecret.isEmpty {
      if let error = model.setSecret(typedSecret, for: endpoint.id) {
        secretError = error
        return
      }
      typedSecret = ""
      // A new key, a new verdict to find.
      endpoint.lastTest = nil
    }
    var list = model.endpoints
    if let index = list.firstIndex(where: { $0.id == endpoint.id }) {
      list[index] = endpoint
    } else {
      list.append(endpoint)
    }
    if await model.save(list), draft?.id == endpoint.id {
      draft = model.endpoints.first { $0.id == endpoint.id }
    }
  }

  private func start(from preset: EndpointsSettingsModel.Preset) {
    var endpoint = preset.endpoint
    if preset.id != EndpointsSettingsModel.otherPresetID {
      endpoint.name = Self.uniqueName(Self.presetName(preset), among: model.endpoints.map(\.name))
    }
    self.preset = preset
    draft = endpoint
    typedSecret = ""
    report = nil
    discoveryError = nil
    // A local server usually answers: its models are read at once.
    if preset.baseURL.hasPrefix("http://localhost") {
      Task { await discover() }
    }
  }

  /// Adds the new endpoint, then shows its own page.
  private func add() async {
    guard let endpoint = draft else { return }
    await saveDraft(endpoint)
    if secretError == nil, model.endpoints.contains(where: { $0.id == endpoint.id }) {
      show(.endpoint(endpoint.id))
    }
  }

  private func duplicate() {
    guard let source = draft else { return }
    var copy = source
    copy.id = EndpointID()
    copy.lastTest = nil
    copy.name = Self.uniqueName(source.name, among: model.endpoints.map(\.name))
    Task {
      await saveDraft(copy)
      show(.endpoint(copy.id))
    }
  }

  private func remove() {
    guard let endpointID else { return }
    let list = model.endpoints.filter { $0.id != endpointID }
    let index = model.endpoints.firstIndex { $0.id == endpointID } ?? 0
    draft = nil
    Task {
      await model.save(list)
      let next = list.indices.contains(index) ? list[index] : list.last
      show(next.map { .endpoint($0.id) } ?? .newEndpoint)
    }
  }

  private func addModel() {
    let id = newModelID.trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty, draft?.models.contains(where: { $0.id == id }) == false else { return }
    draft?.models.append(EndpointModel(id: id))
    newModelID = ""
  }

  private func discover() async {
    guard let endpoint = draft else { return }
    isDiscovering = true
    defer { isDiscovering = false }
    switch await model.discoverModels(for: endpoint, typedSecret: typedSecret) {
    case .success(let found):
      discoveryError = nil
      // What the user already set on a model is kept; new ones are added after.
      var models = draft?.models ?? []
      for item in found where !models.contains(where: { $0.id == item.id }) {
        models.append(item)
      }
      draft?.models = models
    case .failure(let error):
      discoveryError = error
    }
  }

  private func runTest() async {
    guard let endpoint = draft,
      let name = testedModel ?? endpoint.agentModels.first?.id
    else { return }
    isTesting = true
    defer { isTesting = false }
    let result = await model.test(endpoint, typedSecret: typedSecret, model: name)
    report = result
    if model.endpoints.contains(where: { $0.id == endpoint.id }) {
      await model.record(result, for: endpoint.id)
      draft?.lastTest = model.endpoints.first { $0.id == endpoint.id }?.lastTest
    } else {
      draft?.lastTest = EndpointTestOutcome(
        verdict: result.verdict, date: result.date, model: result.model)
    }
  }

  // MARK: - Authentication

  private enum AuthenticationKind: Hashable {
    case none
    case bearer
    case header
    case query
  }

  private func authenticationKind(_ binding: Binding<Endpoint>) -> Binding<AuthenticationKind> {
    Binding(
      get: {
        switch binding.wrappedValue.authentication {
        case .none: return .none
        case .bearer: return .bearer
        case .header: return .header
        case .query: return .query
        }
      },
      set: { kind in
        switch kind {
        case .none: binding.wrappedValue.authentication = .none
        case .bearer: binding.wrappedValue.authentication = .bearer
        case .header: binding.wrappedValue.authentication = .header(name: "x-api-key")
        case .query: binding.wrappedValue.authentication = .query(name: "key")
        }
      })
  }

  private func authenticationName(_ binding: Binding<Endpoint>) -> Binding<String> {
    Binding(
      get: {
        switch binding.wrappedValue.authentication {
        case .header(let name), .query(let name): return name
        case .none, .bearer: return ""
        }
      },
      set: { name in
        switch binding.wrappedValue.authentication {
        case .header: binding.wrappedValue.authentication = .header(name: name)
        case .query: binding.wrappedValue.authentication = .query(name: name)
        case .none, .bearer: break
        }
      })
  }

  // MARK: - Words

  static func uniqueName(_ name: String, among names: [String]) -> String {
    guard names.contains(name) else { return name }
    var index = 2
    while names.contains("\(name) \(index)") { index += 1 }
    return "\(name) \(index)"
  }

  static func color(of verdict: EndpointTestOutcome.Verdict?) -> Color {
    switch verdict {
    case .passed?: return .green
    case .passedWithWarnings?: return .orange
    case .failed?: return .red
    case nil: return Color(nsColor: .tertiaryLabelColor)
    }
  }

  static func protocolName(_ wire: EndpointWireKind) -> String {
    switch wire {
    case .chatCompletions: return "OpenAI Chat Completions"
    case .responses: return "OpenAI Responses"
    case .messages: return "Anthropic Messages"
    case .custom:
      return String(localized: "Custom", bundle: .module, comment: "An endpoint's protocol.")
    }
  }

  static func automaticHarnessName(for wire: EndpointWireKind) -> String {
    EndpointHarnessChoice.automatic.resolved(for: wire) == .codex ? "Codex" : "Claude Code"
  }

  static func presetName(_ preset: EndpointsSettingsModel.Preset) -> String {
    switch preset.id {
    case EndpointsSettingsModel.otherPresetID:
      return String(
        localized: "Other Server", bundle: .module,
        comment: "A new endpoint that starts from no known server.")
    default:
      return preset.name
    }
  }

  static func presetDetail(_ preset: EndpointsSettingsModel.Preset) -> String {
    switch preset.id {
    case "ollama", "lmstudio":
      return String(localized: "On this Mac, no key", bundle: .module)
    case "openrouter":
      return String(localized: "Cloud, an API key", bundle: .module)
    default:
      return String(
        localized: "An address and its protocol", bundle: .module,
        comment: "Under Other Server, among the servers a new endpoint starts from.")
    }
  }

  static func sentence(_ issue: EndpointValidationIssue) -> String {
    switch issue {
    case .missingName:
      return String(localized: "Give the endpoint a name.", bundle: .module)
    case .invalidURL:
      return String(
        localized: "The base URL must be a full address, such as https://host/v1.",
        bundle: .module)
    case .insecureURL:
      return String(
        localized:
          "Plain HTTP is only accepted on this Mac and on the local network: the key would travel in clear.",
        bundle: .module)
    case .missingAuthenticationName:
      return String(
        localized: "Name the header or the parameter that carries the key.", bundle: .module)
    case .invalidParameters:
      return String(localized: "The default parameters must be a JSON object.", bundle: .module)
    case .missingCustomProtocol:
      return String(
        localized: "A custom endpoint needs its document: start from the example.", bundle: .module)
    case .noToolModel:
      return String(
        localized: "Add a model that can call tools: read them from the endpoint, or type one.",
        bundle: .module)
    }
  }

  static func sentence(_ error: EndpointDiscoveryError) -> String {
    switch error {
    case .noList:
      return String(
        localized: "The endpoint gave no list of models Vibe Manager can read. Type them below.",
        bundle: .module)
    case .failed(let detail):
      return EndpointCheckRow.sentence(for: detail)
        ?? String(localized: "The models could not be read.", bundle: .module)
    }
  }

  static func lastTestSentence(_ outcome: EndpointTestOutcome) -> String {
    let date = outcome.date.formatted(date: .abbreviated, time: .shortened)
    switch outcome.verdict {
    case .passed:
      return String(localized: "Last tested \(date): everything worked.", bundle: .module)
    case .passedWithWarnings:
      return String(localized: "Last tested \(date): it works, with reservations.", bundle: .module)
    case .failed:
      return String(localized: "Last tested \(date): it failed. Test it again.", bundle: .module)
    }
  }
}

/// One line of a test's report: what was checked, and what was found.
struct EndpointCheckRow: View {
  let check: EndpointTestCheck

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.title(check.kind))
        if let detail = check.detail, let sentence = Self.sentence(for: detail) {
          Text(sentence)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var symbol: String {
    switch check.outcome {
    case .passed: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .failed: return "xmark.octagon.fill"
    case .skipped: return "circle.dashed"
    }
  }

  private var color: Color {
    switch check.outcome {
    case .passed: return .green
    case .warning: return .orange
    case .failed: return .red
    case .skipped: return .secondary
    }
  }

  static func title(_ kind: EndpointTestCheck.Kind) -> String {
    switch kind {
    case .reachable: return String(localized: "Reachable", bundle: .module)
    case .authentication: return String(localized: "Authentication", bundle: .module)
    case .answer: return String(localized: "Streamed answer", bundle: .module)
    case .toolCall: return String(localized: "Tool call", bundle: .module)
    case .toolResult: return String(localized: "Answer after the tool", bundle: .module)
    case .usage: return String(localized: "Tokens used", bundle: .module)
    }
  }

  static func sentence(for detail: EndpointTestDetail) -> String? {
    switch detail {
    case .latency(let milliseconds):
      return String(localized: "Answered in \(milliseconds) ms.", bundle: .module)
    case .speed(let first, let perSecond):
      if let perSecond {
        let rounded = Int(perSecond.rounded())
        return String(
          localized: "First words after \(first) ms. Speed: \(rounded) tokens/s.", bundle: .module)
      }
      return String(localized: "First words after \(first) ms.", bundle: .module)
    case .endpointSaid(let status, let message):
      if let status {
        return String(localized: "The endpoint answered \(status): \(message)", bundle: .module)
      }
      return String(localized: "The endpoint said: \(message)", bundle: .module)
    case .unreachable:
      return String(
        localized: "The endpoint cannot be reached. Check the address, and that the server runs.",
        bundle: .module)
    case .timedOut:
      return String(
        localized: "The endpoint did not answer in time. A local model may still be loading.",
        bundle: .module)
    case .refusedKey:
      return String(localized: "The key is refused. Type a new one.", bundle: .module)
    case .noToolCall:
      return String(
        localized:
          "The model answered without calling the tool: it will not be able to read or edit files.",
        bundle: .module)
    case .invalidArguments:
      return String(
        localized: "The model called the tool with arguments that are not valid JSON.",
        bundle: .module)
    case .noAnswerAfterTool:
      return String(localized: "The model said nothing after the tool's result.", bundle: .module)
    case .noUsage:
      return String(
        localized:
          "The endpoint does not say how many tokens it used: the session's usage will stay empty.",
        bundle: .module)
    case .serverSteps(let count):
      return String(localized: "Steps the agent ran on the server: \(count).", bundle: .module)
    }
  }
}
