import AppKit
import QuickLook
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
    let isShell = state == .ready && model.composerMode == .shell
    VStack(alignment: .leading, spacing: 10) {
      if !model.attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(model.attachments, id: \.self) { file in
              AttachmentChip(file: file, siblings: model.attachments) {
                model.removeAttachment(file)
              }
            }
          }
        }
      }
      ZStack(alignment: .topLeading) {
        commandUnderlay(size)
        if model.draft.isEmpty {
          placeholder(state)
            .font(theme.messageFont(size: size))
            .foregroundStyle(theme.secondaryText.color)
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
        ReplaceableTextEditor(text: $model.draft)
          .font(isShell ? theme.codeFont(size: size * 0.92) : theme.messageFont(size: size))
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
              : isShell
                ? shellLabel
                : Text("Message to \(model.agentName)", bundle: .module)
          )
          .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift), !press.modifiers.contains(.option),
              !Self.isComposingText
            else { return .ignored }
            // The list open, Return completes a name begun and sends nothing; otherwise — nothing
            // matching, a description only, a name typed in full — the text goes as it is (#219).
            if insertCommand(onReturn: true) { return .handled }
            Task { await model.send() }
            return .handled
          }
          .onKeyPress(.tab, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]),
              !Self.isComposingText
            else { return .ignored }
            return insertCommand() ? .handled : .ignored
          }
          // ↑ and ↓ recall the messages sent, from the first and the last line only: elsewhere,
          // with a modifier, over a selection or while an input method composes, they move the
          // cursor as always (#123).
          .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            // An arrow comes flagged as a function key of the numeric pad: only the modifiers the
            // user holds count.
            guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]),
              !Self.isComposingText
            else { return .ignored }
            // The list open, the arrows are its own — held down, they walk it.
            if model.showsCommandSuggestions {
              return model.moveCommandSelection(by: press.key == .upArrow ? -1 : 1)
                ? .handled : .ignored
            }
            // A held arrow recalls no message: it moves the cursor, as it always did.
            guard press.phase == .down, let caret = ComposerCaret.current(showing: model.draft)
            else { return .ignored }
            let recalled =
              press.key == .upArrow
              ? caret.isOnFirstLine && model.recallOlderPrompt()
              : caret.isOnLastLine && model.recallNewerPrompt()
            guard recalled else { return .ignored }
            Task { @MainActor in Self.placeCursorAtEnd(of: model.draft) }
            return .handled
          }
          // Page Up and Page Down scroll the messages, End goes back to the last one: the
          // conversation is read from the keyboard without leaving the composer (#227) — unless
          // the draft itself scrolls.
          .onKeyPress(keys: [.pageUp, .pageDown, .end], phases: [.down, .repeat]) { press in
            // A draft taller than its field scrolls with these keys, as any text does.
            guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]),
              !Self.isComposingText, !Self.draftScrolls(in: Self.focusedTextView())
            else { return .ignored }
            switch press.key {
            case .pageUp: model.scrollPage(.up)
            case .pageDown: model.scrollPage(.down)
            default: model.jumpToBottom()
            }
            return .handled
          }
          .onKeyPress(.escape) {
            // A dictation or a discussion under way is ended first (#340, #357).
            if let dictation = model.dictation, dictation.concerns(ObjectIdentifier(model)),
              dictation.phase == .recording || dictation.phase == .discussing
            {
              dictation.cancel()
              return .handled
            }
            // The list of commands closes first (#219).
            if !Self.isComposingText, model.dismissCommandSuggestions() { return .handled }
            // A message recalled is put back first: the draft, then the shell mode, then the agent.
            if !Self.isComposingText, model.cancelPromptRecall() {
              Task { @MainActor in Self.placeCursorAtEnd(of: model.draft) }
              return .handled
            }
            if !Self.isComposingText, model.leaveShellMode() { return .handled }
            guard model.isAgentWorking else { return .ignored }
            Task { await model.interrupt() }
            return .handled
          }
      }
      // While the microphone listens, a wave takes the field's place (#357); the draft stays
      // under it, untouched.
      .overlay {
        if let dictation = model.dictation, let wave = waveStyle(dictation) {
          VoiceWave(level: dictation.level, color: wave.color, isAmbient: wave.isAmbient)
            .padding(.horizontal, 4)
            .background(theme.raised.color)
        }
      }
      HStack(spacing: 8) {
        if isShell {
          // A command takes no attachment: a file dropped is named in it.
          Image(systemName: "terminal")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.warning.color)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
        } else {
          attachMenu(state)
        }
        // One button whatever the mode: the same view, so that a `!` typed, or a question asked,
        // during a recording does not remove it — which would throw the recording away. In shell
        // mode it stays only to stop a recording begun before.
        if let dictation = model.dictation,
          !isShell || dictation.concerns(ObjectIdentifier(model))
        {
          DictationButton(
            model: model, dictation: dictation, isEnabled: state == .ready && !isShell,
            isActive: isActive)
        }
        if let dictation = model.dictation, let line = dictationHint(dictation) {
          line
            .font(theme.interfaceFont(size: appearance.textSize.scaled(11.5)))
            .foregroundStyle(theme.secondaryText.color)
            .lineLimit(1)
        } else if state == .awaitingAnswer || state == .answeringQuestion {
          RequestHint(model: model)
        } else {
          hint(state)
            .font(theme.interfaceFont(size: appearance.textSize.scaled(11.5)))
            .foregroundStyle(theme.secondaryText.color)
            .lineLimit(1)
        }
        Spacer()
        Button {
          Task { await model.send() }
        } label: {
          Image(systemName: isShell ? "return" : "arrow.up")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(model.canSend ? theme.onAccent.color : theme.secondaryText.color)
            .frame(width: 28, height: 28)
            .background(model.canSend ? theme.accent.color : theme.border.color, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel(isShell ? Text("Run", bundle: .module) : Text("Send", bundle: .module))
        .help(
          isShell ? Text("Run (Return)", bundle: .module) : Text("Send (Return)", bundle: .module))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      isShell ? theme.warningBackground.color : theme.raised.color,
      in: RoundedRectangle(cornerRadius: 14)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(isShell ? theme.warning.color : theme.border.color, lineWidth: isShell ? 1.5 : 1)
    )
    .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.06), radius: 2, y: 1)
    // Above the composer, as wide, over the end of the conversation (#219).
    // The guide is set outside the condition: set within it, SwiftUI drops it, and the list hangs
    // down from the composer's top instead.
    .overlay(alignment: .top) {
      Group {
        if model.showsCommandSuggestions {
          CommandSuggestionList(commands: model.commands) { command in
            model.insertCommand(command)
            isFocused = true
            Task { @MainActor in Self.placeCursorAtEnd(of: model.draft) }
          }
        }
      }
      .alignmentGuide(.top) { $0[.bottom] + 8 }
    }
    // A request waits for the composer to be on screen, and is spent once: made before the view
    // existed, it is honoured when it appears (#105).
    .onAppear { takePendingFocusRequest() }
    .onChange(of: model.focusComposerRequest) { takePendingFocusRequest() }
    // A panel's block takes the keyboard: the field lets it go, or SwiftUI would take it back
    // (#219).
    .onChange(of: model.terminalPanel != nil) { _, isOpen in
      if isOpen { isFocused = false }
    }
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
    guard let textView = focusedTextView(),
      textView.string == draft
    else { return }
    let end = NSRange(location: (textView.string as NSString).length, length: 0)
    textView.setSelectedRange(end)
    textView.scrollRangeToVisible(end)
  }

  /// The composer's own text view, when it has the keyboard and shows `draft`: never a search
  /// field's editor, whose text may be as empty as the draft.
  @MainActor static func composerTextView(showing draft: String) -> NSTextView? {
    guard let textView = focusedTextView(), !textView.isFieldEditor, textView.string == draft
    else { return nil }
    return textView
  }

  /// Puts what was dictated where the cursor is, as typing would — so ⌘Z takes it back — when
  /// `field`, the composer's text view when the dictation began, still has the keyboard; at the
  /// end of the draft otherwise (#340).
  @MainActor static func insertDictation(
    _ text: String, into model: ConversationModel, field: NSTextView?
  ) {
    if let textView = field, textView === composerTextView(showing: model.draft) {
      let range = textView.selectedRange()
      let string = textView.string as NSString
      let previous =
        range.location > 0
        ? string.substring(with: NSRange(location: range.location - 1, length: 1)).first : nil
      let end = range.location + range.length
      let next =
        end < string.length ? string.substring(with: NSRange(location: end, length: 1)).first : nil
      textView.insertText(
        DictationTranscript.spaced(text, after: previous, before: next), replacementRange: range)
    } else {
      model.draft += DictationTranscript.spaced(text, after: model.draft.last, before: nil)
    }
  }

  /// An input method — Japanese, Chinese — is still composing: Return confirms its text, and
  /// must not send the prompt.
  @MainActor static var isComposingText: Bool {
    focusedTextView()?.hasMarkedText() ?? false
  }

  /// Whether the draft is taller than its field, which then scrolls it (#227).
  @MainActor static func draftScrolls(in textView: NSTextView?) -> Bool {
    guard let textView, let scrollView = textView.enclosingScrollView else { return false }
    return textView.frame.height > scrollView.contentView.bounds.height + 1
  }

  /// The text view that has the keyboard: the composer's, when it is typed into. Replaced by the
  /// tests, whose window is never on screen and so never the key window.
  @MainActor static var focusedTextView: () -> NSTextView? = {
    NSApp.keyWindow?.firstResponder as? NSTextView
  }

  /// Inserts the entry selected in the list, if it is open — for ↩, only to complete a name
  /// begun. The cursor goes after it.
  private func insertCommand(onReturn: Bool = false) -> Bool {
    guard model.insertSelectedCommand(onReturn: onReturn) else { return false }
    Task { @MainActor in Self.placeCursorAtEnd(of: model.draft) }
    return true
  }

  /// Behind the text, drawn as it is laid out: the command inserted as a token, and what it
  /// expects, dimmed, until something is typed after it (#219). The draft itself stays plain text.
  @ViewBuilder
  private func commandUnderlay(_ size: Double) -> some View {
    if let invocation = model.insertedInvocation, !model.draft.contains("\n") {
      let draft = model.draft
      let blanks = draft.prefix { $0 == " " || $0 == "\t" }
      let rest = draft.dropFirst(blanks.count + invocation.count)
      Text(underlay(blanks: String(blanks), invocation: invocation, rest: String(rest)))
        .font(theme.messageFont(size: size))
        .padding(.leading, 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private func underlay(blanks: String, invocation: String, rest: String) -> AttributedString {
    var token = AttributedString(invocation)
    token.backgroundColor = theme.accent.color.opacity(theme.isDark ? 0.28 : 0.16)
    var text = AttributedString(blanks) + token + AttributedString(rest)
    text.foregroundColor = .clear
    if let hint = model.pendingArgumentHint {
      var dimmed = AttributedString(hint)
      dimmed.foregroundColor = theme.secondaryText.color.opacity(0.8)
      text += dimmed
    }
    return text
  }

  private func attachMenu(_ state: ConversationModel.ComposerState) -> some View {
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
  }

  private var shellLabel: Text {
    model.workingDirectoryName.isEmpty
      ? Text("Shell command", bundle: .module)
      : Text("Shell command in \(model.workingDirectoryName)", bundle: .module)
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

  /// What the dictation of this composer is doing, in place of the hint while it records or
  /// transcribes.
  private func dictationHint(_ dictation: DictationController) -> Text? {
    guard dictation.concerns(ObjectIdentifier(model)) else { return nil }
    switch dictation.phase {
    case .recording:
      return Text("Dictating… let go to insert what you said · Esc to cancel", bundle: .module)
    case .transcribing:
      return dictation.isModelReady
        ? Text("Transcribing…", bundle: .module)
        : Text("Preparing the speech model…", bundle: .module)
    case .discussing:
      switch dictation.discussion {
      case .listening:
        return Text("Discussion · your turn · click the microphone or Esc to end", bundle: .module)
      case .hearing:
        return Text("Discussion · listening…", bundle: .module)
      case .transcribing:
        return dictation.isModelReady
          ? Text("Discussion · transcribing…", bundle: .module)
          : Text("Preparing the speech model…", bundle: .module)
      case .agentWorking:
        return Text("Discussion · \(model.agentName) is working", bundle: .module)
      case .agentSpeaking:
        return Text("Discussion · \(model.agentName) is speaking · speak to cut in", bundle: .module)
      }
    case .idle, .offeringDownload, .downloading, .preparing:
      return nil
    }
  }

  /// The wave in the field's place, and its colour: red while dictating, green when it is the
  /// user's turn, grey while the agent works, violet while it speaks. `nil` when nothing listens.
  private func waveStyle(_ dictation: DictationController) -> (color: Color, isAmbient: Bool)? {
    guard dictation.concerns(ObjectIdentifier(model)) else { return nil }
    switch dictation.phase {
    case .recording:
      return (.red, false)
    case .discussing:
      switch dictation.discussion {
      case .listening, .hearing: return (.green, false)
      case .transcribing, .agentWorking: return (theme.secondaryText.color, true)
      case .agentSpeaking: return (.purple, true)
      }
    case .idle, .offeringDownload, .downloading, .preparing, .transcribing:
      return nil
    }
  }

  @ViewBuilder
  private func hint(_ state: ConversationModel.ComposerState) -> some View {
    if state == .ready, model.composerMode == .shell {
      switch model.shellHold {
      case .attachments:
        Text("Remove the attachments to run a command", bundle: .module)
      case .working:
        Text("Wait for the end of \(model.agentName)'s turn to run a command", bundle: .module)
      case .empty, nil:
        if model.workingDirectoryName.isEmpty {
          Text("Shell command · ↩ run · \\! for a message", bundle: .module)
        } else {
          Text(
            "Shell command in \(model.workingDirectoryName) · ↩ run · \\! for a message",
            bundle: .module)
        }
      }
    } else if state == .ready, model.opensOnBangWithoutShellMode {
      Text("\(model.agentName) has no shell mode: sent as a message", bundle: .module)
    } else if state == .ready {
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
/// A click opens it in Quick Look, ← and → going through the other files joined (#209).
///
/// In the conversation's theme, or in the system's colours where no theme applies — the new
/// session's draft (#291).
public struct AttachmentChip: View {
  let file: URL
  let siblings: [URL]
  let usesSystemColors: Bool
  let remove: () -> Void
  @State private var preview: AttachmentPreview?
  @State private var quickLook: URL?
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.displayScale) private var displayScale

  /// - Parameter siblings: the files joined with it, which Quick Look goes through; itself alone
  ///   when empty.
  public init(
    file: URL, siblings: [URL] = [], usesSystemColors: Bool = false,
    remove: @escaping () -> Void
  ) {
    self.file = file
    self.siblings = siblings.contains(file) ? siblings : [file]
    self.usesSystemColors = usesSystemColors
    self.remove = remove
  }

  public var body: some View {
    HStack(spacing: 8) {
      Button {
        quickLook = file
      } label: {
        HStack(spacing: 8) {
          thumbnail
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5))
          VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: file.lastPathComponent)
              .font(font(size: 12, weight: .semibold))
              .foregroundStyle(usesSystemColors ? Color.primary : theme.text.color)
              .lineLimit(1)
            if let size = fileSize {
              Text(verbatim: size)
                .font(font(size: 11))
                .foregroundStyle(secondary)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(verbatim: file.lastPathComponent))
      .accessibilityHint(Text("Opens a preview", bundle: .module))
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Remove \(file.lastPathComponent)", bundle: .module))
    }
    .padding(.leading, 4)
    .padding(.trailing, 8)
    .padding(.vertical, 4)
    .background(
      usesSystemColors ? Color(nsColor: .controlBackgroundColor) : theme.surface.color,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9).stroke(
        usesSystemColors ? Color(nsColor: .separatorColor) : theme.border.color)
    )
    .help(file.path)
    .quickLookPreview($quickLook, in: siblings)
    .task(id: file) {
      let preview = await AttachmentPreviews.shared.preview(
        for: .file(file, id: file.path), maxPixel: Int(28 * displayScale))
      if !Task.isCancelled { self.preview = preview }
    }
  }

  private var secondary: Color {
    usesSystemColors ? Color.secondary : theme.secondaryText.color
  }

  private func font(size: Double, weight: Font.Weight = .regular) -> Font {
    let size = appearance.textSize.scaled(size)
    return usesSystemColors
      ? .system(size: size, weight: weight) : theme.interfaceFont(size: size, weight: weight)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let image = preview?.thumbnail {
      Image(decorative: image, scale: displayScale).resizable().scaledToFill()
    } else if let icon = preview?.icon {
      Image(nsImage: icon).resizable()
    } else {
      Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(secondary).padding(5)
    }
  }

  private var fileSize: String? {
    guard let bytes = preview?.byteCount else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}

/// What the agent is doing, above the composer, with the way to stop it.
struct ActivityLine: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

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
          Text("Interrupt", bundle: .module, comment: "Interrupts the agent's turn.")
          Text("Esc", bundle: .module, comment: "The Escape key.")
            .foregroundStyle(theme.secondaryText.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border.color))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Interrupt the agent", bundle: .module))
    }
    .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
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
  @Environment(\.conversationAppearance) private var appearance

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
      .font(theme.interfaceFont(size: appearance.textSize.scaled(11.5)))
      .foregroundStyle(theme.secondaryText.color)
      .lineLimit(1)
    }
    .accessibilityElement(children: .contain)
  }
}
