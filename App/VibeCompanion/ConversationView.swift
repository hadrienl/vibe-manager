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
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 8) {
        if isWorking, conversation?.request == nil {
          WorkingLine(
            agent: session?.agentName ?? "L’agent", tool: runningTool,
            interrupt: { channel.interrupt(sessionID) })
        }
        if let request = conversation?.request {
          RequestCard(request: request, sessionID: sessionID)
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
          Label("Vue web", systemImage: "globe")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Menu("Plus", systemImage: "ellipsis") {
          // Escape, as on the Mac: the turn stops, the agent waits for the next message.
          // Whenever it runs: an agent without hooks is seen at rest while it works.
          Button("Interrompre", systemImage: "stop.circle") {
            channel.interrupt(sessionID)
          }
          .disabled(session == nil || session?.activity == .stopped)
          Button("Fermer la session", systemImage: "power", role: .destructive) {
            showsCloseConfirmation = true
          }
          .disabled(session == nil || session?.activity == .stopped)
        }
      }
    }
    .confirmationDialog(
      "Fermer la session ?", isPresented: $showsCloseConfirmation, titleVisibility: .visible
    ) {
      Button("Fermer la session", role: .destructive) { channel.close(sessionID) }
    } message: {
      Text("L’agent s’arrête. La session garde sa conversation et peut être relancée.")
    }
    .onAppear { channel.show(sessionID) }
    .onDisappear { if channel.conversation?.sessionID == sessionID { channel.show(nil) } }
  }

  private var subtitle: String {
    guard let session else { return "" }
    switch session.activity {
    case .working: return "\(session.agentName) au travail"
    case .needsAttention: return "\(session.agentName) attend ta réponse"
    case .idle: return "\(session.agentName) · à toi de jouer"
    case .stopped: return "\(session.agentName) · arrêté"
    }
  }

  /// In place of the field for a session whose agent does not run: nothing typed there would
  /// reach anyone, as on the Mac.
  private func closedBar(_ session: RemoteSession) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(session.hasStarted ? "Session fermée" : "Session jamais lancée")
          .font(.subheadline.weight(.semibold))
        Text(
          session.hasStarted
            ? "L’agent ne tourne plus. Relance-le pour lui écrire."
            : "Démarre l’agent pour lui écrire."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button(session.hasStarted ? "Relancer" : "Démarrer", systemImage: "play.fill") {
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
    guard session?.activity != .stopped, case .tool(_, _, _, true, _) = conversation?.entries.last?.kind
    else { return false }
    return true
  }

  /// The tool the agent runs now, as its row reads.
  private var runningTool: String? {
    guard case .tool(_, let title, _, true, _) = conversation?.entries.last?.kind else { return nil }
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
                Button("Retirer", systemImage: "xmark.circle.fill") { files.remove(at: index) }
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
          Button("Appareil photo", systemImage: "camera") { showsCamera = true }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
          Button("Fichiers", systemImage: "folder") { showsFiles = true }
        } label: {
          Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Joindre une image ou un fichier")
        TextField(
          "Écrire à \(session?.agentName ?? "l’agent")…", text: $draft, axis: .vertical
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
        .accessibilityLabel("Envoyer")
      }
      .padding(.horizontal, 12)
    }
    .photosPicker(
      isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
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
          channel.failure = "« \(url.lastPathComponent) » est trop gros pour être envoyé (6 Mo au plus)."
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

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

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
            .foregroundStyle(.white)
            .background(Color.accentColor, in: .rect(cornerRadius: 18))
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
          .foregroundStyle(failed ? Color.red : .secondary)
          .frame(width: 18)
        Text(verbatim: title).lineLimit(1)
        if let detail {
          Text(verbatim: detail).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        if running { ProgressView().controlSize(.mini) }
      }
      .font(.footnote)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    case .notice(let text):
      Text(verbatim: text)
        .font(.caption)
        .foregroundStyle(.secondary)
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
      .accessibilityLabel("Fermer l’image")
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

/// A permission or a question, answered here as on the Mac.
private struct RequestCard: View {
  let request: RemoteRequest
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @State private var selection: Set<String> = []
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(verbatim: request.title).font(.subheadline.weight(.semibold))
      } icon: {
        Image(systemName: request.kind == .permission ? "checkmark.shield" : "questionmark.bubble")
      }
      .foregroundStyle(.orange)
      if let subject = request.subject {
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
            Text(verbatim: choice.label).frame(maxWidth: .infinity, minHeight: 30)
          }
          .buttonStyle(choice.id == "allowOnce" ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
        }
      } else {
        ForEach(request.choices) { choice in
          Button {
            toggle(choice.id)
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: selection.contains(choice.id) ? "checkmark.circle.fill" : "circle")
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
        }
        if request.allowsText {
          TextField("Autre réponse…", text: $text)
            .textFieldStyle(.roundedBorder)
        }
        Button {
          channel.answer(
            request, in: sessionID, choiceIDs: Array(selection),
            text: text.isEmpty ? nil : text)
        } label: {
          Text("Répondre").frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .disabled(selection.isEmpty && text.isEmpty)
      }
    }
    .padding(14)
    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
    .onChange(of: request.id) { _, _ in
      selection = []
      text = ""
    }
  }

  private func toggle(_ id: String) {
    if request.allowsSeveral {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
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
          Text("\(agent) exécute \(tool)…")
        } else {
          Text("\(agent) écrit…")
        }
      }
      .lineLimit(1)
      .truncationMode(.middle)
      Spacer()
      Button(action: interrupt) {
        Label("Interrompre", systemImage: "stop.fill")
          .labelStyle(.titleAndIcon)
          .font(.footnote.weight(.semibold))
      }
      .buttonStyle(.glass)
      .accessibilityLabel("Interrompre l’agent")
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
    .accessibilityLabel("L’agent travaille")
  }
}
