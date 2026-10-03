import SwiftUI
import VibeApplication

/// The agent's terminal, live, in its conversation, while a command sent from the composer waits
/// in one of its panels — `/mcp` (#219) — or while a dialog no hook reported holds the prompt a
/// message was about to be typed into (#319). The panel is the CLI's own: nothing of it is drawn again,
/// whatever the command and the version of the CLI. The keyboard goes to it: its keys are the
/// panel's.
struct TerminalPanelBlock: View {
  let model: ConversationModel
  let panel: ConversationModel.TerminalPanel
  /// The session's terminal, a second view of it.
  let terminal: AnyView
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  /// About twenty-five lines of the terminal: a panel of the TUI fits, the conversation stays in
  /// sight above.
  static let terminalHeight: CGFloat = 400

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "apple.terminal")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.accent.color)
          .accessibilityHidden(true)
        if let command = panel.command {
          Text(verbatim: command)
            .font(theme.codeFont(size: appearance.textSize.scaled(12.5)))
            .fontWeight(.semibold)
            .foregroundStyle(theme.text.color)
          Text("waits for your choice in \(model.agentName)’s terminal", bundle: .module)
            .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
            .foregroundStyle(theme.secondaryText.color)
            .lineLimit(1)
        } else {
          // A dialog found on screen as a prompt was about to be typed into it (#319).
          Text("\(model.agentName) waits for an answer in its terminal", bundle: .module)
            .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
            .foregroundStyle(theme.text.color)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Button {
          model.showTerminal?()
        } label: {
          Text("Open in the Terminal", bundle: .module)
        }
        .buttonStyle(PanelButtonStyle())
        Button {
          Task { await model.closeTerminalPanel() }
        } label: {
          HStack(spacing: 5) {
            Text("Close", bundle: .module)
            Text("Esc", bundle: .module, comment: "The Escape key.")
              .foregroundStyle(theme.secondaryText.color)
          }
        }
        .buttonStyle(PanelButtonStyle())
        .help(Text("Closes the panel, as Escape does in the terminal", bundle: .module))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      Rectangle().fill(theme.border.color).frame(height: 1)
      terminal
        .frame(height: Self.terminalHeight)
        .frame(maxWidth: .infinity)
    }
    .background(theme.raised.color)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.accent.color, lineWidth: 2))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: Text {
    guard let command = panel.command else {
      return Text("\(model.agentName) waits for an answer in its terminal", bundle: .module)
    }
    return Text("\(command) in \(model.agentName)’s terminal", bundle: .module)
  }
}

private struct PanelButtonStyle: ButtonStyle {
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(theme.interfaceFont(size: appearance.textSize.scaled(12)))
      .foregroundStyle(theme.text.color)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border.color))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
