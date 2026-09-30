import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// A session shown as a conversation (#38): messages, the agent's tools folded under titles that
/// say what they did, what it is doing now, and where to write to it.
///
/// Laid out lazily — a session of thousands of messages builds only what is on screen — and kept
/// at the end while the reader is there: scrolling up stops the following, and a pill brings them
/// back to what arrived meanwhile.
public struct ConversationView: View {
  @Bindable var model: ConversationModel
  let theme: ConversationTheme
  let appearance: ConversationAppearance
  /// Whether this is the session on screen: every conversation shown lately stays mounted.
  let isActive: Bool
  /// Whether the composer takes the keyboard when its session comes on screen (#105).
  let claimsKeyboardOnActivation: Bool
  @State private var contentFrame = CGRect.zero
  @State private var viewportHeight = 0.0

  private static let bottomID = "conversation.bottom"

  public init(
    model: ConversationModel, theme: ConversationTheme, appearance: ConversationAppearance,
    isActive: Bool = true, claimsKeyboardOnActivation: Bool = true
  ) {
    self.model = model
    self.theme = theme
    self.appearance = appearance
    self.isActive = isActive
    self.claimsKeyboardOnActivation = claimsKeyboardOnActivation
  }

  public var body: some View {
    VStack(spacing: 0) {
      switch model.snapshot.availability {
      case .loading where model.blocks.isEmpty:
        placeholder {
          ProgressView().controlSize(.small)
          Text("Reading the conversation…", bundle: .module)
        }
      case .notYetWritten(let name) where model.blocks.isEmpty && model.echoes.isEmpty:
        placeholder {
          Image(systemName: "bubble.left.and.text.bubble.right")
            .font(.system(size: 28))
          Text("\(name) has not written anything yet.", bundle: .module)
        }
      case .unsupported, .noAgent:
        placeholder {
          Text("This session has no readable conversation.", bundle: .module)
        }
      default:
        conversation
      }
      // Outside the switch: the first prompt sent turns the empty conversation into a list, and a
      // composer drawn in each case would be a new one then, the keyboard dropped with the old
      // one (#105).
      if showsComposer { footer }
    }
    // The theme's picture, when it has one, stays where it is while the messages scroll (#118).
    .background(ThemeBackdropView(theme: theme))
    .environment(\.conversationTheme, theme)
    .environment(\.conversationAppearance, appearance)
    .environment(\.colorScheme, theme.colorScheme)
    // Coming on screen is when the composer takes the keyboard, as the terminal does (#105): only
    // then, never for a message that arrives or a state that changes. Asked of the model rather
    // than of the composer, which is drawn again whenever the conversation changes shape.
    .onAppear { if isActive { claimKeyboardOnActivation() } }
    .onChange(of: isActive) { _, isActive in
      if isActive {
        claimKeyboardOnActivation()
      } else {
        // Put away before its composer could take it — the conversation still being read — a
        // request is dropped: shown again later, the session must not act on it.
        _ = model.takePendingFocusRequest()
      }
    }
    // Read through the terminal's observable state: the end of the process reaches the model.
    .onChange(of: model.isProcessRunning) { model.processStateChanged() }
    .onChange(of: model.pendingCall?.callID) { _, id in
      guard id != nil else { return }
      let said =
        model.activity == .awaitingUser(.question)
        ? String(localized: "\(model.agentName) is asking you a question", bundle: .module)
        : String(localized: "\(model.agentName) asks for your permission", bundle: .module)
      AccessibilityNotification.Announcement(said).post()
    }
  }

  /// Everywhere but while a conversation not read yet is loading, or one that cannot be read.
  private var showsComposer: Bool {
    switch model.snapshot.availability {
    case .loading where model.blocks.isEmpty, .unsupported, .noAgent: false
    default: true
    }
  }

  private func claimKeyboardOnActivation() {
    if claimsKeyboardOnActivation { model.requestComposerFocus() }
  }

  /// The theme's layout, at the density the user chose (#118).
  private var layout: ConversationTheme.Layout { theme.layout.at(appearance.density) }

  private var spacing: Double { layout.blockSpacing }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: spacing) {
          ForEach(model.blocks) { block in
            BlockView(block: block, model: model)
              .id(block.id)
          }
          ForEach(model.echoes) { echo in
            VStack(alignment: .trailing, spacing: 4) {
              if echo.kind.isShell {
                // Running from the moment it is sent: the transcript completes it.
                ShellRunView(
                  id: echo.id.uuidString, run: ShellRun(command: echo.text), model: model,
                  isEcho: true, dismiss: { model.dismissEcho(echo.id) })
                if echo.state == .unconfirmed { echoStatus(echo) }
              } else {
                UserPromptView(
                  text: echo.text, attachments: echo.attachmentCount, date: echo.sentAt,
                  isEcho: true)
                echoStatus(echo)
              }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottomID)
        }
        .frame(maxWidth: layout.contentWidth)
        .padding(.horizontal, layout.sideMargin)
        .padding(.top, layout.topPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .scrollView)
        } action: { frame in
          contentFrame = frame
          model.scrollGeometryChanged(contentFrame: frame, viewportHeight: viewportHeight)
        }
      }
      .onGeometryChange(for: Double.self) {
        $0.size.height
      } action: { height in
        viewportHeight = height
        model.scrollGeometryChanged(contentFrame: contentFrame, viewportHeight: height)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: model.scrollToBottomRequest) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
      .onChange(of: model.revealRequest) {
        guard let id = model.revealedBlockID else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
      }
      .overlay(alignment: .bottom) {
        if model.scroll.unseenCount > 0 {
          Button {
            model.jumpToBottom()
          } label: {
            Label {
              Text("\(model.scroll.unseenCount) new messages", bundle: .module)
            } icon: {
              Image(systemName: "arrow.down")
            }
            .font(theme.interfaceFont(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.raised.color, in: Capsule())
            .overlay(Capsule().stroke(theme.border.color))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
          }
          .buttonStyle(.plain)
          .padding(.bottom, 10)
        }
      }
      .accessibilityRotor(Text("Messages", bundle: .module)) {
        ForEach(model.blocks.filter(Self.isPrompt)) { block in
          AccessibilityRotorEntry(Text(Self.rotorLabel(block)), id: block.id)
        }
      }
      .accessibilityRotor(Text("Failures", bundle: .module)) {
        ForEach(model.blocks.filter(Self.isFailure)) { block in
          AccessibilityRotorEntry(Text(verbatim: block.id), id: block.id)
        }
      }
      .accessibilityRotor(Text("Sub-agents", bundle: .module)) {
        ForEach(model.blocks.filter(Self.holdsSubagents)) { block in
          AccessibilityRotorEntry(
            Text(
              verbatim: block.calls.map(SubagentPresentation.description(of:))
                .joined(separator: ", ")),
            id: block.id)
        }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Out of the messages that scroll: a sub-agent in the background runs long after its block
      // has gone up (#180).
      if !model.trayItems.isEmpty {
        SubagentTray(model: model)
      }
      if model.isAgentWorking {
        ActivityLine(model: model)
      }
      if model.composerState == .stopped, model.canRestart(), let restart = model.restart {
        HStack {
          Label {
            Text("The session is stopped. Its history stays readable.", bundle: .module)
          } icon: {
            Image(systemName: "stop.circle")
          }
          .font(theme.interfaceFont(size: 12.5))
          .foregroundStyle(theme.secondaryText.color)
          Spacer()
          Button(action: restart) {
            Text("Restart", bundle: .module)
          }
        }
      }
      PromptComposer(model: model, isActive: isActive)
    }
    .frame(maxWidth: layout.contentWidth)
    .padding(.horizontal, layout.sideMargin)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
    // Behind the messages only: the composer keeps the plain background.
    .background(theme.backdrop.area == .messages ? theme.background.color : .clear)
  }

  @ViewBuilder
  private func echoStatus(_ echo: PendingEcho) -> some View {
    switch echo.state {
    case .sending:
      Text("Sending…", bundle: .module)
        .font(theme.interfaceFont(size: 11))
        .foregroundStyle(theme.secondaryText.color)
    case .unconfirmed:
      HStack(spacing: 8) {
        Text("Not confirmed by the agent yet", bundle: .module)
        Button {
          model.showTerminal?()
        } label: {
          Text("Show the Terminal", bundle: .module)
        }
        .buttonStyle(.link)
        Button {
          model.dismissEcho(echo.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Dismiss", bundle: .module))
      }
      .font(theme.interfaceFont(size: 11))
      .foregroundStyle(theme.warning.color)
    }
  }

  private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 10, content: content)
      .font(theme.interfaceFont(size: 13))
      .foregroundStyle(theme.secondaryText.color)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private static func isPrompt(_ block: ConversationBlock) -> Bool {
    if case .entry(let entry) = block { return entry.isUserPrompt }
    return false
  }

  private static func holdsSubagents(_ block: ConversationBlock) -> Bool {
    block.calls.contains { $0.kind == .subagent }
  }

  private static func isFailure(_ block: ConversationBlock) -> Bool {
    if case .failed = block.toolState { return true }
    return false
  }

  private static func rotorLabel(_ block: ConversationBlock) -> String {
    guard case .entry(let entry) = block, case .userPrompt(let text, _) = entry.content else {
      return block.id
    }
    return String(text.prefix(80))
  }
}

/// One block of the conversation, or of a sub-agent's activity.
struct BlockView: View {
  let block: ConversationBlock
  let model: ConversationModel
  /// Inside a sub-agent's activity.
  var isNested = false

  var body: some View {
    switch block {
    case .toolGroup:
      ToolBlockView(block: block, model: model)
    case .subagentGroup:
      SubagentGroupView(block: block, model: model)
    case .entry(let entry):
      switch entry.content {
      case .userPrompt(let text, let attachments):
        UserPromptView(text: text, attachments: attachments, date: entry.date)
      case .agentText(let text):
        AgentTextView(text: text)
      case .reasoning(let text):
        ReasoningRow(id: entry.id, text: text, model: model)
      case .tool(let call) where call.kind == .subagent:
        SubagentBlockView(call: call, model: model, isNested: isNested)
      case .tool:
        ToolBlockView(block: block, model: model)
      case .notice(.shell(let run)):
        ShellRunView(id: entry.id, run: run, model: model)
      case .notice(let notice):
        NoticeRow(notice: notice)
      }
    }
  }
}
