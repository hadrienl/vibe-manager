import AppKit
import SwiftUI
import VibeApplication

/// What the user sent: a bubble on the right, or a line with a mark, as the settings say.
struct UserPromptView: View {
  let text: String
  let attachments: Int
  let date: Date?
  var isEcho = false
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize
    Group {
      if appearance.userMessageStyle == .bubbles {
        HStack {
          Spacer(minLength: 80)
          VStack(alignment: .trailing, spacing: 6) {
            content(size: size)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .background(theme.bubble.color)
              .clipShape(
                UnevenRoundedRectangle(
                  topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                  topTrailingRadius: 16)
              )
              .overlay {
                if let border = theme.bubbleBorder {
                  UnevenRoundedRectangle(
                    topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                    topTrailingRadius: 16
                  ).stroke(border.color, lineWidth: 1.5)
                }
              }
          }
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.color).frame(width: 3)
          VStack(alignment: .leading, spacing: 4) {
            Text("You", bundle: .module)
              .font(theme.interfaceFont(size: size * 0.78, weight: .semibold))
              .foregroundStyle(theme.secondaryText.color)
            content(size: size)
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
      }
    }
    .opacity(isEcho ? 0.55 : 1)
    .contextMenu {
      Button {
        copy(text)
      } label: {
        Text("Copy Message", bundle: .module)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel(Text("You said: \(text)", bundle: .module))
  }

  @ViewBuilder
  private func content(size: Double) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if !text.isEmpty {
        Text(verbatim: text)
          .font(theme.messageFont(size: size))
          .foregroundStyle(
            appearance.userMessageStyle == .bubbles ? theme.bubbleText.color : theme.text.color
          )
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if attachments > 0 {
        Label {
          Text("\(attachments) attachments", bundle: .module)
        } icon: {
          Image(systemName: "paperclip")
        }
        .font(theme.interfaceFont(size: size * 0.8))
        .foregroundStyle(theme.secondaryText.color)
      }
    }
  }
}

/// What the agent answered, in full width.
struct AgentTextView: View {
  let text: String

  var body: some View {
    MarkdownView(text: text)
      .contextMenu {
        Button {
          copy(text)
        } label: {
          Text("Copy as Markdown", bundle: .module)
        }
      }
  }
}

/// The agent's reasoning, folded. When its provider keeps the text to itself, the row says so and
/// does not unfold: it never promises what it does not have.
struct ReasoningRow: View {
  let id: String
  let text: String?
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let _ = model.toggleRevision
    let isExpanded = model.isExpanded(id: id, default: false)
    let size = appearance.textSize.pointSize * 0.86
    VStack(alignment: .leading, spacing: 6) {
      Button {
        if text != nil { model.setExpanded(!isExpanded, for: id) }
      } label: {
        HStack(spacing: 8) {
          if text != nil {
            Image(systemName: "chevron.right")
              .font(.system(size: size * 0.75, weight: .semibold))
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
          Image(systemName: "lightbulb")
          if text == nil {
            Text("Reasoning not shared by the agent", bundle: .module)
          } else {
            Text("Reasoning", bundle: .module)
          }
        }
        .font(theme.interfaceFont(size: size))
        .foregroundStyle(theme.secondaryText.color)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(text == nil)
      .accessibilityValue(
        text == nil
          ? Text(verbatim: "")
          : isExpanded ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module))
      if isExpanded, let text {
        HStack(alignment: .top, spacing: 10) {
          Rectangle().fill(theme.border.color).frame(width: 2)
          MarkdownView(text: text)
            .opacity(0.85)
        }
        .padding(.leading, 18)
      }
    }
  }
}

/// Something that happened to the conversation rather than in it.
struct NoticeRow: View {
  let notice: ConversationNotice
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize * 0.82
    Group {
      switch notice {
      case .chapter(let name, let date):
        HStack(spacing: 10) {
          line
          Text(
            verbatim: date.map { "\(name) · \($0.formatted(date: .abbreviated, time: .shortened))" }
              ?? name
          )
          .fixedSize()
          line
        }
      case .interrupted:
        centered(Text("Interrupted", bundle: .module), symbol: "stop.circle")
      case .compacted:
        centered(
          Text("Context compacted", bundle: .module), symbol: "arrow.down.right.and.arrow.up.left")
      case .olderFormat:
        centered(
          Text("This transcript is too old to show the agent's tools.", bundle: .module),
          symbol: "clock.arrow.circlepath")
      case .command(let command):
        leading(Text(verbatim: command), symbol: "command", monospaced: true)
      case .shell(let command, let output):
        VStack(alignment: .leading, spacing: 4) {
          leading(Text(verbatim: "! " + command), symbol: "terminal", monospaced: true)
          if let output, !output.isEmpty {
            Text(verbatim: output)
              .font(theme.codeFont(size: size))
              .foregroundStyle(theme.secondaryText.color)
              .lineLimit(12)
              .textSelection(.enabled)
              .padding(.leading, 24)
          }
        }
      case .error(let text):
        leading(Text(verbatim: text), symbol: "exclamationmark.triangle.fill", color: theme.failure)
      case .information(let text):
        leading(Text(verbatim: text), symbol: "info.circle")
      }
    }
    .font(theme.interfaceFont(size: size))
    .foregroundStyle(theme.secondaryText.color)
  }

  private var line: some View {
    Rectangle().fill(theme.border.color).frame(height: 1)
  }

  private func centered(_ text: Text, symbol: String) -> some View {
    HStack(spacing: 10) {
      line
      Label {
        text
      } icon: {
        Image(systemName: symbol)
      }
      .fixedSize()
      line
    }
  }

  private func leading(
    _ text: Text, symbol: String, monospaced: Bool = false, color: ThemeColor? = nil
  ) -> some View {
    Label {
      text
        .font(
          monospaced
            ? theme.codeFont(size: appearance.textSize.pointSize * 0.82)
            : theme.interfaceFont(size: appearance.textSize.pointSize * 0.82)
        )
        .textSelection(.enabled)
    } icon: {
      Image(systemName: symbol)
    }
    .foregroundStyle((color ?? theme.secondaryText).color)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

@MainActor
func copy(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
