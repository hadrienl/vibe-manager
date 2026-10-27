import CompanionCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A session's conversation, live (#400): the Mac sends it whole at each change while it is shown.
/// What the agent waits for is answered in a card above the field; the field writes to the agent.
struct ConversationView: View {
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @State private var draft = ""
  /// The screen's height: what a request's card may take of it.
  @State private var height: CGFloat = 800
  @FocusState private var fieldFocused: Bool
  /// The files joined to the next message.
  @State private var files: [RemoteFile] = []
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var showsPhotos = false
  @State private var showsCamera = false
  @State private var showsFiles = false
  @State private var showsCloseConfirmation = false

  private var session: RemoteSession? { channel.sessions.first { $0.id == sessionID } }
  private var conversation: RemoteConversation? {
    channel.conversation?.sessionID == sessionID ? channel.conversation : nil
  }

  @Environment(\.colorScheme) private var colorScheme

  /// The session's theme, as the Mac draws its conversation (#274), in the phone's appearance.
  private var palette: ConversationPalette {
    guard let theme = conversation?.theme ?? lastTheme else { return .system }
    return ConversationPalette(
      colorScheme == .dark ? theme.dark : theme.light, font: theme.fontStyle)
  }
  /// Kept while a conversation reloads, so that the colours do not flash.
  @State private var lastTheme: RemoteTheme?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if conversation == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
        ForEach(conversation?.entries ?? []) { entry in
          EntryView(entry: entry)
        }

      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .defaultScrollAnchor(.bottom)
    .background(palette.background.ignoresSafeArea())
    .foregroundStyle(palette.text)
    .fontDesign(palette.fontDesign)
    .tint(palette.accent)
    .environment(\.conversationPalette, palette)
    .onChange(of: conversation?.theme) { _, theme in if let theme { lastTheme = theme } }
    .scrollDismissesKeyboard(.interactively)
    // The whole screen's, keyboard and request card aside: what the card may take of it does
    // not move with the card itself.
    .background {
      Color.clear.ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 8) {
        if isWorking, conversation?.request == nil {
          WorkingLine(
            agent: session?.agentName ?? String(localized: "The agent"), tool: runningTool,
            interrupt: { channel.interrupt(sessionID) })
        }
        if let request = conversation?.request {
          RequestCard(request: request, sessionID: sessionID, maxHeight: height * 0.5)
            .padding(.horizontal, 12)
        }
        if let session, session.activity == .stopped {
          closedBar(session)
        } else {
          inputBar
        }
      }
      .padding(.bottom, 6)
    }
    .navigationTitle(session?.name ?? "")
    .navigationSubtitle(subtitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          WebMirrorView(sessionID: sessionID)
        } label: {
          Label("Web View", systemImage: "globe")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Menu("More", systemImage: "ellipsis") {
          Button("Close Session", systemImage: "power", role: .destructive) {
            showsCloseConfirmation = true
          }
          .disabled(session == nil || session?.activity == .stopped)
        }
      }
    }
    .confirmationDialog(
      "Close the session?", isPresented: $showsCloseConfirmation, titleVisibility: .visible
    ) {
      Button("Close Session", role: .destructive) { channel.close(sessionID) }
    } message: {
      Text("The agent stops. The session keeps its conversation and can be restarted.")
    }
    .onAppear { channel.show(sessionID) }
    .onDisappear { if channel.conversation?.sessionID == sessionID { channel.show(nil) } }
  }

  private var subtitle: String {
    guard let session else { return "" }
    switch session.activity {
    case .working: return String(localized: "\(session.agentName) is working")
    case .needsAttention: return String(localized: "\(session.agentName) is waiting for you")
    case .idle: return String(localized: "\(session.agentName) · your turn")
    case .stopped: return String(localized: "\(session.agentName) · stopped")
    }
  }

  /// In place of the field for a session whose agent does not run: nothing typed there would
  /// reach anyone, as on the Mac.
  private func closedBar(_ session: RemoteSession) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(session.hasStarted ? "Session Closed" : "Session Never Started")
          .font(.subheadline.weight(.semibold))
        Text(
          session.hasStarted
            ? "Its agent no longer runs. Restart it to write to it."
            : "Start its agent to write to it."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button(session.hasStarted ? "Restart" : "Start", systemImage: "play.fill") {
        channel.restart(sessionID)
      }
      .buttonStyle(.glassProminent)
    }
    .padding(14)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
    .padding(.horizontal, 12)
  }

  /// The agent at work: said by its activity, or by a tool still running — an agent without
  /// hooks says nothing of its work.
  private var isWorking: Bool {
    if session?.activity == .working { return true }
    guard session?.activity != .stopped,
      case .tool(_, _, _, true, _) = conversation?.entries.last?.kind
    else { return false }
    return true
  }

  /// The tool the agent runs now, as its row reads.
  private var runningTool: String? {
    guard case .tool(_, let title, _, true, _) = conversation?.entries.last?.kind else {
      return nil
    }
    return title
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
  }

  private var inputBar: some View {
    VStack(spacing: 6) {
      if !files.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(Array(files.enumerated()), id: \.offset) { index, file in
              HStack(spacing: 4) {
                Image(systemName: Self.isImage(file.name) ? "photo" : "doc")
                Text(verbatim: file.name).lineLimit(1)
                Button("Remove", systemImage: "xmark.circle.fill") { files.remove(at: index) }
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.secondary)
              }
              .font(.caption)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .glassEffect(.regular, in: Capsule())
            }
          }
          .padding(.horizontal, 12)
        }
      }
      HStack(alignment: .bottom, spacing: 8) {
        Menu {
          Button("Photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
          Button("Camera", systemImage: "camera") { showsCamera = true }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
          Button("Files", systemImage: "folder") { showsFiles = true }
        } label: {
          Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Attach a Photo or a File")
        TextField(
          "Message \(session?.agentName ?? String(localized: "the agent"))…", text: $draft,
          axis: .vertical
        )
        .lineLimit(1...6)
        .focused($fieldFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        Button {
          let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          guard canSend else { return }
          channel.send(text, files: files, to: sessionID)
          draft = ""
          files = []
        } label: {
          Image(systemName: "arrow.up")
            .font(.body.weight(.bold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(!canSend)
        .accessibilityLabel("Send")
      }
      .padding(.horizontal, 12)
    }
    .photosPicker(
      isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images
    )
    .onChange(of: photoItems) { _, items in
      guard !items.isEmpty else { return }
      photoItems = []
      Task {
        for (index, item) in items.enumerated() {
          guard let data = try? await item.loadTransferable(type: Data.self),
            let jpeg = Self.jpeg(UIImage(data: data))
          else { continue }
          files.append(RemoteFile(name: "photo-\(Self.stamp())-\(index + 1).jpg", data: jpeg))
        }
      }
    }
    .fullScreenCover(isPresented: $showsCamera) {
      CameraPicker { image in
        if let jpeg = Self.jpeg(image) {
          files.append(RemoteFile(name: "photo-\(Self.stamp()).jpg", data: jpeg))
        }
      }
      .ignoresSafeArea()
    }
    .fileImporter(
      isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      for url in urls {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 6_000_000 else {
          channel.failure = .other(
            String(localized: "“\(url.lastPathComponent)” is too large to send (6 MB at most)."))
          continue
        }
        files.append(RemoteFile(name: url.lastPathComponent, data: data))
      }
    }
  }

  /// A photo as the agent reads it: 2048 pixels at most, in JPEG.
  static func jpeg(_ image: UIImage?) -> Data? {
    guard let image else { return nil }
    let longest = max(image.size.width, image.size.height)
    let scale = min(1, 2048 / max(longest, 1))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    return resized.jpegData(compressionQuality: 0.8)
  }

  static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  static func isImage(_ name: String) -> Bool {
    UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false
  }
}

/// The camera, as UIKit offers it.
private struct CameraPicker: UIViewControllerRepresentable {
  let take: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_: UIImagePickerController, context _: Context) {
    // The picker keeps no state of the view's to follow.
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate
  {
    let parent: CameraPicker
    init(_ parent: CameraPicker) { self.parent = parent }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage { parent.take(image) }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}

private struct EntryView: View {
  let entry: RemoteEntry
  @Environment(\.conversationPalette) private var palette

  var body: some View {
    switch entry.kind {
    case .user(let text, let attachments):
      VStack(alignment: .trailing, spacing: 6) {
        if !attachments.isEmpty {
          AttachmentStrip(attachments: attachments)
        }
        if !text.isEmpty {
          Text(verbatim: text)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .foregroundStyle(palette.bubbleText)
            .background(palette.bubble, in: .rect(cornerRadius: 18))
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.leading, 48)
    case .agent(let text):
      Text(Self.markdown(text))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    case .tool(let symbol, let title, let detail, let running, let failed):
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(failed ? palette.failure : palette.secondaryText)
          .frame(width: 18)
        Text(verbatim: title).lineLimit(1)
        if let detail {
          Text(verbatim: detail).foregroundStyle(palette.secondaryText).lineLimit(1)
        }
        Spacer(minLength: 0)
        if running { ProgressView().controlSize(.mini) }
      }
      .font(.footnote)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(palette.raised, in: .rect(cornerRadius: 10))
    case .notice(let notice):
      Group {
        switch notice {
        case .interrupted: Text("Interrupted")
        case .compacted: Text("Conversation summarized")
        case .shell(let command): Text(verbatim: "$ \(command)")
        case .error(let text): Text(verbatim: text)
        }
      }
      .font(.caption)
      .foregroundStyle(palette.secondaryText)
      .frame(maxWidth: .infinity)
    }
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// The files of a message: the pictures of its images, a chip for the rest.
private struct AttachmentStrip: View {
  let attachments: [RemoteAttachment]
  @Environment(RemoteChannel.self) private var channel
  @State private var shown: UIImage?

  var body: some View {
    HStack(spacing: 6) {
      ForEach(attachments) { attachment in
        if attachment.isImage, let path = attachment.path {
          Group {
            if let image = channel.attachmentImage(path) {
              Button {
                shown = image
              } label: {
                Image(uiImage: image)
                  .resizable()
                  .scaledToFill()
              }
              .buttonStyle(.plain)
            } else {
              Color(.secondarySystemBackground).overlay { ProgressView() }
            }
          }
          .frame(width: 140, height: 140)
          .clipShape(.rect(cornerRadius: 14))
          .accessibilityLabel(attachment.name)
        } else {
          Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc")
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
      }
    }
    .fullScreenCover(item: $shown.identified) { item in
      ZoomedImage(image: item.image)
    }
  }
}

/// An image whole, on black, closed with a tap.
private struct ZoomedImage: View {
  let image: UIImage
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .scaledToFit()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.black)
      .onTapGesture { dismiss() }
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("Close the Image")
  }
}

private struct IdentifiedImage: Identifiable {
  let image: UIImage
  var id: ObjectIdentifier { ObjectIdentifier(image) }
}

extension Binding where Value == UIImage? {
  fileprivate var identified: Binding<IdentifiedImage?> {
    Binding<IdentifiedImage?>(
      get: { wrappedValue.map(IdentifiedImage.init) }, set: { wrappedValue = $0?.image })
  }
}

/// A permission or questions, answered here as on the Mac: one answer per question, sent together.
private struct RequestCard: View {
  let request: RemoteRequest
  let sessionID: String
  /// Past it, several questions fold up, one open at a time, and scroll if need be.
  let maxHeight: CGFloat
  @Environment(RemoteChannel.self) private var channel
  /// The choices taken and the words typed, by question.
  @State private var selections: [Int: Set<String>] = [:]
  @State private var texts: [Int: String] = [:]
  /// The question unfolded when they fold up: the first unanswered one unless the user picks.
  @State private var opened: Int?
  /// The questions' height, all open: measured off screen, so the card folds before it overflows.
  @State private var openHeight: CGFloat = 0

  private var isFolded: Bool { isSeveral && openHeight > maxHeight }

  private var questions: [RemoteQuestion] { request.shownQuestions }
  private var isSeveral: Bool { questions.count > 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Group {
          if isSeveral || request.title.isEmpty {
            Text(request.kind == .permission ? "Allow this command?" : "The agent asks you")
          } else {
            Text(verbatim: request.title)
          }
        }
        .font(.subheadline.weight(.semibold))
      } icon: {
        Image(systemName: request.kind == .permission ? "checkmark.shield" : "questionmark.bubble")
      }
      .foregroundStyle(.orange)
      if !isSeveral, let subject = request.subject {
        Text(verbatim: subject)
          .font(.footnote.monospaced())
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
      }
      if request.kind == .permission {
        ForEach(request.choices) { choice in
          Button(role: choice.isDestructive ? .destructive : nil) {
            channel.answer(request, in: sessionID, choiceIDs: [choice.id], text: nil)
          } label: {
            Text(Self.label(of: choice)).frame(maxWidth: .infinity, minHeight: 30)
          }
          .buttonStyle(
            choice.id == "allowOnce" ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
        }
      } else {
        if isFolded {
          ScrollView { questionList(folded: true) }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
        } else if isSeveral {
          questionList(folded: false)
        } else if let question = questions.first {
          choices(of: question, at: 0)
        }
        Button {
          channel.answer(request, in: sessionID, answers: answers)
        } label: {
          Text(isSeveral ? "Send Answers" : "Answer").frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .disabled(!answers.allSatisfy(\.isGiven))
      }
    }
    .padding(14)
    .background {
      if isSeveral {
        questionList(folded: false)
          .fixedSize(horizontal: false, vertical: true)
          .padding(14)
          .hidden()
          .onGeometryChange(for: CGFloat.self, of: \.size.height) { openHeight = $0 }
      }
    }
    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
    .onChange(of: request.id) { _, _ in
      selections = [:]
      texts = [:]
      opened = nil
    }
  }

  /// Every question open, or folded up to its title and answer, all but one.
  private func questionList(folded: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        if index > 0 { Divider() }
        let isOpen = !folded || index == openedIndex
        if folded {
          Button {
            withAnimation(.snappy) { opened = index }
          } label: {
            HStack(alignment: .top) {
              heading(of: question, at: index, isOpen: isOpen)
              Spacer(minLength: 0)
              Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        } else {
          heading(of: question, at: index, isOpen: true)
        }
        if isOpen { choices(of: question, at: index) }
      }
    }
  }

  /// A question's header and title, and its answer once folded.
  private func heading(of question: RemoteQuestion, at index: Int, isOpen: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let header = question.header, !header.isEmpty {
        Text(verbatim: header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      Text(verbatim: question.title).font(.subheadline.weight(.semibold))
      if !isOpen, let summary = summary(of: question, at: index) {
        Text(verbatim: summary).font(.caption).foregroundStyle(.tint).lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var openedIndex: Int {
    opened ?? answers.firstIndex { !$0.isGiven } ?? 0
  }

  /// What a folded question was answered: its choices' labels, or the words typed.
  private func summary(of question: RemoteQuestion, at index: Int) -> String? {
    if let text = texts[index], !text.isEmpty { return text }
    let chosen = selections[index] ?? []
    let labels = question.choices.filter { chosen.contains($0.id) }.map(\.label)
    return labels.isEmpty ? nil : labels.formatted(.list(type: .and))
  }

  @ViewBuilder
  private func choices(of question: RemoteQuestion, at index: Int) -> some View {
    let selection = selections[index] ?? []
    ForEach(question.choices) { choice in
      Button {
        toggle(choice.id, of: question, at: index)
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: Self.symbol(chosen: selection.contains(choice.id), of: question))
            .foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: choice.label).font(.subheadline.weight(.semibold))
            if let detail = choice.detail {
              Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(selection.contains(choice.id) ? .isSelected : [])
    }
    // A question of several choices has no field on the Mac's dialog: words would not reach it.
    if question.allowsText, !question.allowsSeveral {
      TextField(
        "Another answer…",
        text: Binding(get: { texts[index] ?? "" }, set: { texts[index] = $0 })
      )
      .textFieldStyle(.roundedBorder)
    }
  }

  /// Rounds for a single choice, boxes for several, as on the Mac.
  static func symbol(chosen: Bool, of question: RemoteQuestion) -> String {
    switch (question.allowsSeveral, chosen) {
    case (true, true): "checkmark.square.fill"
    case (true, false): "square"
    case (false, true): "checkmark.circle.fill"
    case (false, false): "circle"
    }
  }

  /// One per question, in order.
  private var answers: [RemoteAnswer] {
    questions.indices.map { index in
      let text = texts[index] ?? ""
      return RemoteAnswer(
        choiceIDs: Array(selections[index] ?? []).sorted(), text: text.isEmpty ? nil : text)
    }
  }

  /// A permission's choices come unlabelled: said here, in the phone's language.
  static func label(of choice: RemoteChoice) -> String {
    switch choice.id {
    case "allowOnce": String(localized: "Allow")
    case "allowAlways": String(localized: "Always Allow")
    case "deny": String(localized: "Deny")
    default: choice.label
    }
  }

  private func toggle(_ id: String, of question: RemoteQuestion, at index: Int) {
    var selection = selections[index] ?? []
    if question.allowsSeveral {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
    }
    selections[index] = selection
    // A single choice answers its question: the next unanswered one unfolds.
    if !question.allowsSeveral, opened == index || opened == nil {
      withAnimation(.snappy) {
        opened = answers.indices.first { $0 != index && !answers[$0].isGiven } ?? index
      }
    }
  }
}

/// Either glass style, picked at run time.
private struct AnyButtonStyle: PrimitiveButtonStyle {
  private let make: (Configuration) -> AnyView

  init(_ style: some PrimitiveButtonStyle) {
    make = { AnyView(style.makeBody(configuration: $0)) }
  }

  func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// What the agent does, over the field, and the way to interrupt it: the Mac's line, word for
/// word.
private struct WorkingLine: View {
  let agent: String
  let tool: String?
  let interrupt: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Group {
        if let tool {
          Text("\(agent) is running \(tool)…")
        } else {
          Text("\(agent) is writing…")
        }
      }
      .lineLimit(1)
      .truncationMode(.middle)
      Spacer()
      Button(action: interrupt) {
        Label("Interrupt", systemImage: "stop.fill")
          .labelStyle(.titleAndIcon)
          .font(.footnote.weight(.semibold))
      }
      .buttonStyle(.glass)
      .accessibilityLabel("Interrupt the Agent")
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
  }
}

private struct TypingDots: View {
  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<3) { index in
        Circle()
          .fill(.secondary)
          .frame(width: 7, height: 7)
          .opacity(1 - Double(index) * 0.3)
      }
    }
    .accessibilityLabel("The agent is working")
  }
}

/// The colours of a conversation, from its theme or the system's.
struct ConversationPalette {
  var background: Color
  var raised: Color
  var text: Color
  var secondaryText: Color
  var accent: Color
  var bubble: Color
  var bubbleText: Color
  var failure: Color
  var fontDesign: Font.Design

  static let system = ConversationPalette(
    background: Color(.systemBackground), raised: Color(.secondarySystemBackground),
    text: .primary, secondaryText: .secondary, accent: .accentColor, bubble: .accentColor,
    bubbleText: .white, failure: .red, fontDesign: .default)

  init(
    background: Color, raised: Color, text: Color, secondaryText: Color, accent: Color,
    bubble: Color, bubbleText: Color, failure: Color, fontDesign: Font.Design
  ) {
    self.background = background
    self.raised = raised
    self.text = text
    self.secondaryText = secondaryText
    self.accent = accent
    self.bubble = bubble
    self.bubbleText = bubbleText
    self.failure = failure
    self.fontDesign = fontDesign
  }

  init(_ theme: RemotePalette, font: String) {
    func color(_ hex: String, _ fallback: Color) -> Color { Color(hex: hex) ?? fallback }
    self.init(
      background: color(theme.background, Color(.systemBackground)),
      raised: color(theme.raised, Color(.secondarySystemBackground)),
      text: color(theme.text, .primary), secondaryText: color(theme.secondaryText, .secondary),
      accent: color(theme.accent, .accentColor), bubble: color(theme.bubble, .accentColor),
      bubbleText: color(theme.bubbleText, .white), failure: color(theme.failure, .red),
      fontDesign: font == "serif" ? .serif : font == "monospaced" ? .monospaced : .default)
  }
}

extension EnvironmentValues {
  @Entry var conversationPalette = ConversationPalette.system
}
