import AppKit
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
  /// A second view of the session's terminal, shown while a command waits in one of its panels
  /// (#219). `nil` where there is no terminal to show.
  /// It is given what Escape does in it: close the block.
  /// and what to tell of what its screen shows.
  let liveTerminal:
    (
      (
        _ focusRequest: Int, _ onEscape: @escaping () -> Void,
        _ onScreen: @escaping (String) -> Void
      ) -> AnyView
    )?
  /// Space as the microphone (#357), for the window this conversation is in.
  @State private var voiceKeys = VoiceKeyMonitor()
  @State private var window: NSWindow?
  @State private var contentFrame = CGRect.zero
  @State private var viewportHeight = 0.0
  @State private var pager = ConversationPager()
  /// Where a page leads, in the messages: a mark that SwiftUI scrolls to (#227).
  @State private var pageTarget = 0.0

  private static let bottomID = "conversation.bottom"
  private static let pageTargetID = "conversation.page"

  public init(
    model: ConversationModel, theme: ConversationTheme, appearance: ConversationAppearance,
    isActive: Bool = true, claimsKeyboardOnActivation: Bool = true,
    liveTerminal: (
      (
        _ focusRequest: Int, _ onEscape: @escaping () -> Void,
        _ onScreen: @escaping (String) -> Void
      ) -> AnyView
    )? = nil
  ) {
    self.liveTerminal = liveTerminal
    self.model = model
    self.theme = theme
    self.appearance = appearance
    self.isActive = isActive
    self.claimsKeyboardOnActivation = claimsKeyboardOnActivation
  }

  public var body: some View {
    let _ = BodyCounter.tick(.conversationView)
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
    }
    // Over the end of the messages, which scroll under it, rather than below them (#359).
    .modifier(
      ComposerBar(theme: theme) {
        // Out of the footer: a session started on a command shows its panel while its
        // conversation, empty, is still read and the composer not shown yet (#219).
        if let panel = model.terminalPanel, let liveTerminal {
          TerminalPanelBlock(
            model: model, panel: panel,
            terminal: liveTerminal(
              model.terminalPanelFocusRequest,
              { model.escapeInTerminalPanel() },
              { model.terminalScreenChanged($0) })
          )
          .frame(maxWidth: layout.contentWidth)
          .padding(.horizontal, layout.sideMargin)
          .padding(.bottom, showsComposer ? 8 : 16)
          .frame(maxWidth: .infinity)
        }
        // Outside the switch: the first prompt sent turns the empty conversation into a list, and
        // a composer drawn in each case would be a new one then, the keyboard dropped with the old
        // one (#105).
        if showsComposer { footer }
      }
    )
    .environment(\.conversationTheme, theme)
    .environment(\.conversationAppearance, appearance)
    .environment(\.conversationIsLive, isActive)
    .environment(\.readAloud, model.readAloud)
    // The voice loaded while the conversation is read, not when its first answer is (#357).
    // The models loaded while the conversation is read, the dictation's first (#357): their
    // first load compiles them for this Mac, which takes minutes. One at a time.
    .task {
      model.dictation?.warmUp()
      model.readAloud?.warmUp()
    }
    // Space as the microphone, in the conversation on screen (#357).
    .background(WindowReader { window = $0 })
    .onChange(of: isActive, initial: true) { updateVoiceKeys() }
    .onChange(of: window) { updateVoiceKeys() }
    .onDisappear { voiceKeys.stop() }
    // The audio mode (#357): the answers that arrive are read, in the conversation on screen.
    .onChange(of: model.agentAnswers.map(\.id), initial: true) { followAnswers() }
    .onChange(of: isActive) { followAnswers() }
    .environment(\.colorScheme, theme.colorScheme)
    // Coming on screen is when the composer takes the keyboard, as the terminal does (#105): only
    // then, never for a message that arrives or a state that changes. Asked of the model rather
    // than of the composer, which is drawn again whenever the conversation changes shape.
    .onAppear { if isActive { claimKeyboardOnActivation() } }
    // Every conversation shown lately stays mounted: only the one on screen is laid out (#250).
    .onChange(of: isActive, initial: true) { _, isActive in model.setShown(isActive) }
    .onDisappear {
      model.setShown(false)
      model.readAloud?.forget(ObjectIdentifier(model))
    }
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
    // Hidden too: a permission or a question in a session not on screen is said all the same.
    .onChange(of: model.announcedCallID) { _, id in
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
                  text: echo.text, attachments: echo.messageAttachments, date: echo.sentAt,
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
        // Short, the conversation fills the view from the bottom rather than leaving its emptiness
        // to the scroll view's top inset, which macOS 26 covers with the toolbar's edge effect
        // (#228).
        .frame(minHeight: viewportHeight, alignment: .bottom)
        // Inside the scroll view of the messages: the pager finds it from here (#227).
        .background(ConversationPagerProbe(pager: pager).accessibilityHidden(true))
        .overlay(alignment: .topLeading) {
          // Laid out there, not drawn there: an offset would leave it where SwiftUI scrolls to.
          Color.clear
            .frame(width: 1, height: 1)
            .id(Self.pageTargetID)
            .padding(.top, max(pageTarget, 0))
            .accessibilityHidden(true)
        }
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
      .modifier(ToolbarVeil())
      .onChange(of: model.scrollToBottomRequest) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
      .onChange(of: model.pageRequest) {
        guard let top = pager.readableTop(after: model.pageRequest.page) else { return }
        pageTarget = top
        // Once the mark has moved there.
        DispatchQueue.main.async { proxy.scrollTo(Self.pageTargetID, anchor: .top) }
      }
      .onChange(of: model.revealRequest) {
        guard let id = model.revealedBlockID else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
      }
      .overlay(alignment: .top) {
        if let readAloud = model.readAloud, readAloud.isReading {
          ReadingAloudPill(readAloud: readAloud)
        }
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
            .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5), weight: .semibold))
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(
              ConversationGlass(
                shape: Capsule(), fill: theme.raised.color, border: theme.border.color,
                isInteractive: true, shadowRadius: 6, shadowOpacity: 0.2, shadowY: 2))
          }
          .buttonStyle(.plain)
          .padding(.bottom, 10)
        }
      }
      .accessibilityRotor(Text("Messages", bundle: .module)) {
        ForEach(model.promptBlocks) { block in
          AccessibilityRotorEntry(Text(Self.rotorLabel(block)), id: block.id)
        }
      }
      .accessibilityRotor(Text("Failures", bundle: .module)) {
        ForEach(model.failureBlocks) { block in
          AccessibilityRotorEntry(
            Text(verbatim: ToolBlockView.accessibilityTitle(of: block)), id: block.id)
        }
      }
      .accessibilityRotor(Text("Sub-agents", bundle: .module)) {
        ForEach(model.subagentBlocks) { block in
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
        ActivityLine(model: model).modifier(StatusGlass())
      }
      if model.composerState == .stopped, let failure = model.shownLaunchFailure {
        HStack(alignment: .firstTextBaseline) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(failure.message)
              if let suggestion = failure.suggestion {
                Text(suggestion).foregroundStyle(theme.secondaryText.color)
              }
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
          Spacer()
          stoppedActions
        }
        .modifier(StatusGlass())
      } else if model.composerState == .stopped, model.hasStoppedOnError {
        HStack {
          Label {
            Text(
              "The agent stopped on an error. Its terminal says why.", bundle: .module,
              comment: "Under a conversation whose agent ended on its own, not closed by the user.")
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
          .foregroundStyle(theme.secondaryText.color)
          Spacer()
          stoppedActions
        }
        .modifier(StatusGlass())
      } else if model.composerState == .stopped, model.canRestart(), let restart = model.restart {
        HStack {
          Label {
            Text("The session is stopped. Its history stays readable.", bundle: .module)
          } icon: {
            Image(systemName: "stop.circle")
          }
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
          .foregroundStyle(theme.secondaryText.color)
          Spacer()
          Button(action: restart) {
            Text("Restart", bundle: .module)
          }
        }
        .modifier(StatusGlass())
      }
      PromptComposer(model: model, isActive: isActive)
    }
    .frame(maxWidth: layout.contentWidth)
    .padding(.horizontal, layout.sideMargin)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
    .modifier(PlainFooterBackground(theme: theme))
  }

  /// The way to the terminal, which says why, and Restart, for an agent that stopped on an error.
  @ViewBuilder
  private var stoppedActions: some View {
    if let showTerminal = model.showTerminal {
      Button(action: showTerminal) {
        Text("Show the Terminal", bundle: .module)
      }
    }
    if model.canRestart(), let restart = model.restart {
      Button(action: restart) {
        Text("Restart", bundle: .module)
      }
    }
  }

  @ViewBuilder
  private func echoStatus(_ echo: PendingEcho) -> some View {
    switch echo.state {
    case .sending:
      Text("Sending…", bundle: .module)
        .font(theme.interfaceFont(size: appearance.textSize.scaled(11)))
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
      .font(theme.interfaceFont(size: appearance.textSize.scaled(11)))
      .foregroundStyle(theme.warning.color)
    }
  }

  private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 10, content: content)
      .font(theme.interfaceFont(size: appearance.textSize.scaled(13)))
      .foregroundStyle(theme.secondaryText.color)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        AgentTextView(text: text, readAloud: model.readAloud)
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

/// The terminal panel and the footer, laid over the end of the messages on macOS 26: they scroll
/// under the composer's glass instead of stopping short above it (#359). Before, below them.
///
/// The theme's picture, when it has one, stays where it is while the messages scroll (#118), and
/// as the bar grows: laid over the whole view, never over the messages' part of it, which shrinks
/// for a long draft or the agent's activity, and the picture filling it would be cropped anew.
/// Behind the messages only, the plain background covers it under the bar, behind the messages
/// that scroll there.
private struct ComposerBar<Bar: View>: ViewModifier {
  let theme: ConversationTheme
  @ViewBuilder let bar: Bar
  @State private var barHeight = 0.0

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        // An inset, not a bar: under a bar, macOS 26 blurs its whole height as soon as it grows
        // for the agent's activity, cut sharp at the top — the very break the glass removes.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) { bar }
            .onGeometryChange(for: Double.self) {
              $0.size.height
            } action: {
              barHeight = $0
            }
        }
        .background {
          ThemeBackdropView(theme: theme)
            .overlay(alignment: .bottom) {
              if theme.backdrop.area == .messages {
                theme.background.color.frame(height: barHeight)
              }
            }
            .ignoresSafeArea()
        }
    } else {
      VStack(spacing: 0) {
        content
        bar
      }
      .background { ThemeBackdropView(theme: theme).ignoresSafeArea() }
    }
  }
}

/// Before macOS 26, a picture behind the messages only leaves the footer the plain background.
private struct PlainFooterBackground: ViewModifier {
  let theme: ConversationTheme

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
    } else {
      content.background(theme.backdrop.area == .messages ? theme.background.color : .clear)
    }
  }
}

/// What scrolls under the toolbar is blurred the whole height of it.
///
/// The soft edge effect of macOS 26 blurs the top of the toolbar only and fades out towards its
/// foot: a message level with the title or the pickers stayed legible under them. The hard one
/// blurs it all, under a veil of the window's background. Before macOS 26 there is no edge effect.
private struct ToolbarVeil: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.scrollEdgeEffectStyle(.hard, for: .top)
    } else {
      content
    }
  }
}

extension ConversationView {
  /// Tells the reading aloud the answers this conversation has now, and whether it is on screen.
  fileprivate func followAnswers() {
    model.readAloud?.follow(
      model.agentAnswers, in: ObjectIdentifier(model), isOnScreen: isActive)
  }
}

extension ConversationView {
  /// Installs Space as the microphone while this conversation is on screen, and takes it away
  /// when it is not.
  fileprivate func updateVoiceKeys() {
    guard isActive, let dictation = model.dictation, window != nil else {
      voiceKeys.stop()
      return
    }
    let model = model
    voiceKeys.start(
      in: window,
      VoiceKeyMonitor.Actions(
        press: {
          guard model.acceptsInput || dictation.phase == .discussing else { return }
          model.readAloud?.stop()
          dictation.pressBegan(model.dictationRequest())
        },
        release: { dictation.pressEnded(model.dictationRequest()) },
        escape: {
          guard dictation.concerns(ObjectIdentifier(model)),
            dictation.phase == .discussing || dictation.phase == .recording
          else { return false }
          dictation.cancel()
          return true
        }))
  }
}
