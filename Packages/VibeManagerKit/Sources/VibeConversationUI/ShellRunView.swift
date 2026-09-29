import SwiftUI
import VibeApplication

/// A shell command the user ran with `!` (#188), on the user's side of the conversation: the
/// agent's own commands are tool blocks, on the other.
///
/// The command heads it, then its state, then what it printed — folded past a few lines.
struct ShellRunView: View {
  let id: String
  let run: ShellRun
  let model: ConversationModel?
  /// Sent from the composer, not in the transcript yet.
  var isEcho = false
  /// Takes an echo away, should its command never reach the transcript.
  var dismiss: (() -> Void)?
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  static let foldedLineCount = 12

  var body: some View {
    let size = appearance.textSize.pointSize * 0.86
    HStack {
      Spacer(minLength: 80)
      VStack(alignment: .leading, spacing: 8) {
        header(size: size)
        output(size: size)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(theme.surface.color)
      .clipShape(RoundedRectangle(cornerRadius: theme.layout.blockRadius))
      .overlay(
        RoundedRectangle(cornerRadius: theme.layout.blockRadius)
          .stroke(theme.warning.color, lineWidth: 1))
    }
    .opacity(isEcho ? 0.7 : 1)
    .contextMenu {
      Button {
        copy(Self.transcript(of: run))
      } label: {
        Text("Copy", bundle: .module)
      }
      Button {
        copy(run.command)
      } label: {
        Text("Copy Command", bundle: .module)
      }
      if let model {
        Button {
          model.editAgain(run)
        } label: {
          Text("Edit Again", bundle: .module, comment: "Puts a shell command back in the composer.")
        }
        .disabled(model.composerState != .ready)
      }
      if let dismiss {
        Divider()
        Button {
          dismiss()
        } label: {
          Text("Dismiss", bundle: .module)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      Text("You ran \(run.command), \(StateSymbol.label(for: run.state))", bundle: .module))
  }

  private func header(size: Double) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "terminal")
        .foregroundStyle(theme.warning.color)
      Text(verbatim: "! " + run.command)
        .font(theme.codeFont(size: size))
        .foregroundStyle(theme.text.color)
        .textSelection(.enabled)
        .lineLimit(6)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      stateLabel
        .font(theme.interfaceFont(size: size * 0.9))
        .foregroundStyle(theme.secondaryText.color)
      StateSymbol(state: run.state)
    }
  }

  @ViewBuilder
  private var stateLabel: some View {
    switch run.state {
    case .running: Text("Running…", bundle: .module)
    case .failed(let exitCode?): Text("Exit code \(String(exitCode))", bundle: .module)
    case .interrupted: Text("Interrupted", bundle: .module)
    default: EmptyView()
    }
  }

  @ViewBuilder
  private func output(size: Double) -> some View {
    let texts = [run.output, run.errorOutput].compactMap { $0 }
    if texts.isEmpty {
      if run.state.isFinished {
        Text("No output", bundle: .module)
          .font(theme.interfaceFont(size: size * 0.95))
          .foregroundStyle(theme.secondaryText.color)
      }
    } else {
      let lineCount = texts.reduce(0) { $0 + Self.lineCount(of: $1.text) }
      let foldable = lineCount > Self.foldedLineCount
      let isExpanded = model?.isExpanded(id: id, default: false) ?? false
      let _ = model?.toggleRevision
      let shown = foldable && !isExpanded ? Self.folded(texts) : texts.map(\.text)
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(zip(texts, shown).enumerated()), id: \.offset) { _, pair in
            let (output, text) = pair
            if !text.isEmpty {
              Text(verbatim: text)
                .font(theme.codeFont(size: size))
                .foregroundStyle(output.isError ? theme.failure.color : theme.codeText.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.layout.innerRadius))
        HStack(spacing: 12) {
          if foldable, let model {
            Button {
              model.setExpanded(!isExpanded, for: id)
            } label: {
              isExpanded
                ? Text("Show Less", bundle: .module)
                : Text("Show All \(lineCount) Lines", bundle: .module)
            }
            .buttonStyle(.link)
          }
          if let omitted = texts.map(\.omittedByteCount).max(), omitted > 0 {
            Text(
              "\(ByteCountFormatter.string(fromByteCount: Int64(omitted), countStyle: .file)) left out of the middle",
              bundle: .module, comment: "An amount of text, such as 3 MB.")
          }
          Spacer()
          Button {
            copy(Self.transcript(of: run))
          } label: {
            Label {
              Text("Copy", bundle: .module)
            } icon: {
              Image(systemName: "doc.on.doc")
            }
          }
          .buttonStyle(.plain)
          .help(Text("Copy the command and its output", bundle: .module))
        }
        .font(theme.interfaceFont(size: size * 0.9))
        .foregroundStyle(theme.secondaryText.color)
      }
    }
  }

  static func lineCount(of text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false).count
  }

  /// The first lines of the outputs, folded: twelve in all, the output first, then the errors.
  static func folded(_ outputs: [ToolOutput]) -> [String] {
    var budget = foldedLineCount
    return outputs.map { output in
      let lines = output.text.split(separator: "\n", omittingEmptySubsequences: false)
      defer { budget = max(0, budget - lines.count) }
      return lines.prefix(budget).joined(separator: "\n")
    }
  }

  /// The command and what it printed, as a terminal would show them.
  static func transcript(of run: ShellRun) -> String {
    ([PromptHistory.recalled(command: run.command)]
      + [run.output, run.errorOutput].compactMap { $0?.text })
      .joined(separator: "\n")
  }
}
