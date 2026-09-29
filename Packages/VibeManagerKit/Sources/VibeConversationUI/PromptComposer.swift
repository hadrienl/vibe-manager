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
  /// Whether its session is the one on screen: a hidden composer never takes the keyboard.
  var isActive = true
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @FocusState private var isFocused: Bool

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
        ReplaceableTextEditor(text: $model.draft)
          .font(theme.messageFont(size: size))
          .foregroundStyle(theme.text.color)
          .scrollContentBackground(.hidden)
          .frame(minHeight: size * 1.6, maxHeight: size * 1.5 * 8)
          .fixedSize(horizontal: false, vertical: true)
          // A file dropped on the field is a chip, as anywhere else on the conversation (#146).
          .overlay(ComposerFileDropCatcher())
          .focused($isFocused)
          .disabled(state != .ready && state != .answeringQuestion)
          .accessibilityLabel(
            state == .answeringQuestion
              ? Text("Other answer to \(model.agentName)", bundle: .module)
              : Text("Message to \(model.agentName)", bundle: .module)
          )
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
            model.chooseFiles?()
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
        if state == .awaitingAnswer || state == .answeringQuestion {
          RequestHint(model: model)
        } else {
          hint(state)
            .font(theme.interfaceFont(size: 11.5))
            .foregroundStyle(theme.secondaryText.color)
            .lineLimit(1)
        }
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
    // A request waits for the composer to be on screen, and is spent once: made before the view
    // existed, it is honoured when it appears (#105).
    .onAppear { takePendingFocusRequest() }
    .onChange(of: model.focusComposerRequest) { takePendingFocusRequest() }
    .onChange(of: isActive) { takePendingFocusRequest() }
  }

  /// Takes the keyboard if it was asked for and can be typed into; a request the composer cannot
  /// honour — its agent stopped, a permission awaited — is dropped, and the keyboard stays put.
  /// Put away, a request is dropped as well: coming back later must not act on it.
  private func takePendingFocusRequest() {
    guard model.takePendingFocusRequest(), isActive, model.acceptsInput else { return }
    // On the next turn: the view that comes on screen is enabled in the same update, and a
    // disabled field does not take the focus.
    Task { @MainActor in
      guard isActive, model.acceptsInput else { return }
      isFocused = true
      Task { @MainActor in Self.placeCursorAtEnd(of: model.draft) }
    }
  }

  /// Back in a draft, the user carries on where it ends — not at its first letter.
  @MainActor static func placeCursorAtEnd(of draft: String) {
    guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
      textView.string == draft
    else { return }
    let end = NSRange(location: (textView.string as NSString).length, length: 0)
    textView.setSelectedRange(end)
    textView.scrollRangeToVisible(end)
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
    case .answeringQuestion:
      Text("Another answer…", bundle: .module, comment: "The composer, as a question's Other.")
    case .awaitingAnswer: Text("Answer the request first", bundle: .module)
    case .starting:
      Text(
        "\(model.agentName) is starting. If it asks something first, answer in the terminal.",
        bundle: .module)
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
/// What the agent waits on, said quietly beside the composer — the request itself is the block
/// above — with the way to its terminal, where every request can be answered.
struct RequestHint: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    HStack(spacing: 6) {
      Button {
        model.showTerminal?()
      } label: {
        Image(systemName: "apple.terminal")
          .font(.system(size: 12, weight: .medium))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.secondaryText.color)
      .help(Text("Answer in the Terminal", bundle: .module))
      .accessibilityLabel(Text("Answer in the Terminal", bundle: .module))
      Group {
        if model.composerState == .answeringQuestion {
          Text("↩ sends this answer · ⇧↩ new line", bundle: .module)
        } else if model.activity == .awaitingUser(.question) {
          Text("\(model.agentName) is asking you a question", bundle: .module)
        } else {
          Text("\(model.agentName) asks for your permission", bundle: .module)
        }
      }
      .font(theme.interfaceFont(size: 11.5))
      .foregroundStyle(theme.secondaryText.color)
      .lineLimit(1)
    }
    .accessibilityElement(children: .contain)
  }
}
