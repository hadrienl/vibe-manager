import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// Where the user writes to the agent (#38): a field that grows up to eight lines, the files
/// joined to the message, a "+" menu, and Send.
///
/// What is sent is written into the session's terminal as a keyboard would: the terminal stays
/// the one road to the agent. The field is closed while the agent waits for an answer there —
/// text typed into a permission prompt would be read as the answer.
struct PromptComposer: View {
  @Bindable var model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @FocusState private var isFocused: Bool
  @State private var isChoosingFiles = false

  var body: some View {
    let size = appearance.textSize.pointSize
    let state = model.composerState
    VStack(alignment: .leading, spacing: 10) {
      if !model.attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(model.attachments, id: \.self) { file in
              AttachmentChip(file: file) { model.removeAttachment(file) }
            }
          }
        }
      }
      ZStack(alignment: .topLeading) {
        if model.draft.isEmpty {
          placeholder(state)
            .font(theme.messageFont(size: size))
            .foregroundStyle(theme.secondaryText.color)
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
        TextEditor(text: $model.draft)
          .font(theme.messageFont(size: size))
          .foregroundStyle(theme.text.color)
          .scrollContentBackground(.hidden)
          .frame(minHeight: size * 1.6, maxHeight: size * 1.5 * 8)
          .fixedSize(horizontal: false, vertical: true)
          .focused($isFocused)
          .disabled(state != .ready)
          .accessibilityLabel(Text("Message to \(model.agentName)", bundle: .module))
          .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift), !press.modifiers.contains(.option),
              !Self.isComposingText
            else { return .ignored }
            Task { await model.send() }
            return .handled
          }
          .onKeyPress(.escape) {
            guard model.isAgentWorking else { return .ignored }
            Task { await model.interrupt() }
            return .handled
          }
      }
      HStack(spacing: 8) {
        Menu {
          Button {
            isChoosingFiles = true
          } label: {
            Label {
              Text("Attach Files…", bundle: .module)
            } icon: {
              Image(systemName: "paperclip")
            }
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(theme.surface.color, in: Circle())
            .overlay(Circle().stroke(theme.border.color))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(theme.text.color)
        .disabled(state != .ready)
        .accessibilityLabel(Text("Add", bundle: .module))
        hint(state)
          .font(theme.interfaceFont(size: 11.5))
          .foregroundStyle(theme.secondaryText.color)
          .lineLimit(1)
        Spacer()
        Button {
          Task { await model.send() }
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(model.canSend ? theme.onAccent.color : theme.secondaryText.color)
            .frame(width: 28, height: 28)
            .background(model.canSend ? theme.accent.color : theme.border.color, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel(Text("Send", bundle: .module))
        .help(Text("Send (Return)", bundle: .module))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border.color))
    .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.06), radius: 2, y: 1)
    .fileImporter(
      isPresented: $isChoosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) { result in
      if case .success(let files) = result { model.attach(files) }
    }
    .onChange(of: model.focusComposerRequest) { isFocused = true }
  }

  /// An input method — Japanese, Chinese — is still composing: Return confirms its text, and
  /// must not send the prompt.
  @MainActor static var isComposingText: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
  }

  @ViewBuilder
  private func placeholder(_ state: ConversationModel.ComposerState) -> some View {
    switch state {
    case .ready: Text("Write to \(model.agentName)…", bundle: .module)
    case .awaitingAnswer: Text("Answer the request in the terminal first", bundle: .module)
    case .stopped: Text("The session is stopped.", bundle: .module)
    case .unavailable: Text("Write to the agent in the terminal.", bundle: .module)
    }
  }

  @ViewBuilder
  private func hint(_ state: ConversationModel.ComposerState) -> some View {
    if state == .ready {
      if model.isAgentWorking {
        Text("↩ send · ⇧↩ new line · sent when the turn ends", bundle: .module)
      } else {
        Text("↩ send · ⇧↩ new line", bundle: .module)
      }
    } else {
      Text(verbatim: "")
    }
  }
}

/// A file joined to the message: its icon or thumbnail, its name, its size, and a way to remove it.
struct AttachmentChip: View {
  let file: URL
  let remove: () -> Void
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      thumbnail
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5))
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: file.lastPathComponent)
          .font(theme.interfaceFont(size: 12, weight: .semibold))
          .foregroundStyle(theme.text.color)
          .lineLimit(1)
        if let size = fileSize {
          Text(verbatim: size)
            .font(theme.interfaceFont(size: 11))
            .foregroundStyle(theme.secondaryText.color)
        }
      }
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(theme.secondaryText.color)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Remove \(file.lastPathComponent)", bundle: .module))
    }
    .padding(.leading, 4)
    .padding(.trailing, 8)
    .padding(.vertical, 4)
    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border.color))
    .help(file.path)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
      let image = NSImage(contentsOf: file)
    {
      Image(nsImage: image).resizable().scaledToFill()
    } else {
      Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable()
    }
  }

  private var fileSize: String? {
    guard let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      return nil
    }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}

/// What the agent is doing, above the composer, with the way to stop it.
struct ActivityLine: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small).tint(theme.accent.color)
      Group {
        if let call = model.runningCall {
          let title = ToolCallSummary.title(for: call).title
          Text("\(model.agentName) is running \(title)…", bundle: .module)
        } else {
          Text("\(model.agentName) is writing…", bundle: .module)
        }
      }
      .lineLimit(1)
      .truncationMode(.middle)
      Spacer()
      Button {
        Task { await model.interrupt() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "stop.fill").font(.system(size: 9))
          Text("Stop", bundle: .module)
          Text("Esc", bundle: .module, comment: "The Escape key.")
            .foregroundStyle(theme.secondaryText.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border.color))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Stop the agent", bundle: .module))
    }
    .font(theme.interfaceFont(size: 12.5))
    .foregroundStyle(theme.secondaryText.color)
    .accessibilityElement(children: .contain)
  }
}

/// The agent waits for the user in its terminal: said in orange, with the way there.
struct PendingRequestBanner: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(theme.warning.color)
        .font(.system(size: 16))
      VStack(alignment: .leading, spacing: 2) {
        if model.activity == .awaitingUser(.question) {
          Text("\(model.agentName) is asking you a question", bundle: .module)
            .font(theme.interfaceFont(size: 13, weight: .semibold))
        } else {
          Text("\(model.agentName) asks for your permission", bundle: .module)
            .font(theme.interfaceFont(size: 13, weight: .semibold))
        }
        if let call = model.pendingCall {
          let title = ToolCallSummary.title(for: call)
          Text(verbatim: call.parameter(.command) ?? call.parameter(.question) ?? title.title)
            .font(theme.codeFont(size: 12))
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      .foregroundStyle(theme.text.color)
      Spacer()
      Button {
        model.showTerminal?()
      } label: {
        Text("Answer in the Terminal", bundle: .module)
          .font(theme.interfaceFont(size: 12, weight: .semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .foregroundStyle(theme.isDark ? Color.black : Color.white)
          .background(theme.warning.color, in: RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(.plain)
    }
    .padding(12)
    .background(theme.warningBackground.color, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.warning.color.opacity(0.6)))
    .accessibilityElement(children: .contain)
  }
}
