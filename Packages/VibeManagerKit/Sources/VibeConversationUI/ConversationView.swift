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
  @State private var isDropTargeted = false
  @AccessibilityFocusState private var bannerFocused: Bool

  private static let bottomID = "conversation.bottom"

  public init(
    model: ConversationModel, theme: ConversationTheme, appearance: ConversationAppearance
  ) {
    self.model = model
    self.theme = theme
    self.appearance = appearance
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
        footer
      case .unsupported, .noAgent:
        placeholder {
          Text("This session has no readable conversation.", bundle: .module)
        }
      default:
        conversation
        footer
      }
    }
    .background(theme.background.color)
    .environment(\.conversationTheme, theme)
    .environment(\.conversationAppearance, appearance)
    .environment(\.colorScheme, theme.colorScheme)
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .stroke(theme.accent.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
          .background(theme.accent.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            Label {
              Text("Drop to attach to your message", bundle: .module)
            } icon: {
              Image(systemName: "square.and.arrow.down")
            }
            .font(theme.interfaceFont(size: 15, weight: .semibold))
            .foregroundStyle(theme.text.color)
          }
          .padding(14)
          .allowsHitTesting(false)
      }
    }
    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
      guard model.composerState == .ready else { return false }
      for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in model.attach([url]) }
        }
      }
      return true
    }
    .onChange(of: model.pendingCall?.callID) { _, id in
      if id != nil { bannerFocused = true }
    }
  }

  private var spacing: Double { appearance.density == .compact ? 10 : 18 }

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
              UserPromptView(
                text: echo.text, attachments: echo.attachmentCount, date: echo.sentAt, isEcho: true)
              echoStatus(echo)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottomID)
            .onAppear { model.bottomVisibilityChanged(true) }
            .onDisappear { model.bottomVisibilityChanged(false) }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 32)
        .padding(.top, appearance.density == .compact ? 14 : 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: model.scrollToBottomRequest) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
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
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.pendingCall != nil || model.composerState == .awaitingAnswer {
        PendingRequestBanner(model: model)
          .accessibilityFocused($bannerFocused)
      } else if model.isAgentWorking {
        ActivityLine(model: model)
      }
      if model.composerState == .stopped, let restart = model.restart {
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
      PromptComposer(model: model)
    }
    .frame(maxWidth: 820)
    .padding(.horizontal, 32)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
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

/// One block of the conversation.
struct BlockView: View {
  let block: ConversationBlock
  let model: ConversationModel

  var body: some View {
    switch block {
    case .toolGroup:
      ToolBlockView(block: block, model: model)
    case .entry(let entry):
      switch entry.content {
      case .userPrompt(let text, let attachments):
        UserPromptView(text: text, attachments: attachments, date: entry.date)
      case .agentText(let text):
        AgentTextView(text: text)
      case .reasoning(let text):
        ReasoningRow(id: entry.id, text: text, model: model)
      case .tool:
        ToolBlockView(block: block, model: model)
      case .notice(let notice):
        NoticeRow(notice: notice)
      }
    }
  }
}
