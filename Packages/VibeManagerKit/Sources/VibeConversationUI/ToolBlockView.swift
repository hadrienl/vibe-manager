import AppKit
import SwiftUI
import VibeApplication

/// A tool call, or a group of them, folded under a title that says what it did (#38).
///
/// The state shows without unfolding — a spinner, a check, a red octagon, an orange padlock — and
/// never by its colour alone: VoiceOver reads it, and each state has its own symbol.
struct ToolBlockView: View {
  let block: ConversationBlock
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let _ = model.toggleRevision
    let isExpanded = model.isExpanded(block)
    let state = block.toolState ?? .succeeded
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
          model.setExpanded(!isExpanded, for: block.id)
        }
      } label: {
        header(isExpanded: isExpanded, state: state)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityTitle(state: state))
      .accessibilityValue(
        isExpanded ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module)
      )
      .accessibilityHint(Text("Shows or hides the details.", bundle: .module))

      if isExpanded {
        Rectangle().fill(theme.border.color).frame(height: 1)
        details
      }
    }
    .background(theme.surface.color)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(borderColor(state).color, lineWidth: state.severity >= 4 ? 1.5 : 1))
  }

  private var title: ToolCallTitle {
    switch block {
    case .entry(let entry):
      return entry.toolCall.map { ToolCallSummary.title(for: $0) }
        ?? ToolCallTitle(symbolName: "wrench.and.screwdriver", title: "")
    case .toolGroup(_, let calls):
      return ToolCallSummary.title(forGroup: calls.compactMap(\.toolCall))
    }
  }

  private func header(isExpanded: Bool, state: ToolCallState) -> some View {
    let title = title
    let size = appearance.textSize.pointSize * 0.9
    return HStack(spacing: 9) {
      Image(systemName: "chevron.right")
        .font(.system(size: size * 0.75, weight: .semibold))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .foregroundStyle(theme.secondaryText.color)
      Image(systemName: title.symbolName)
        .foregroundStyle(theme.secondaryText.color)
        .frame(width: 18)
      Text(verbatim: title.title)
        .font(theme.interfaceFont(size: size, weight: .semibold))
        .foregroundStyle(theme.text.color)
        .lineLimit(1)
        .truncationMode(.middle)
      if let counts = lineCounts {
        HStack(spacing: 4) {
          Text(verbatim: "+\(counts.added)").foregroundStyle(theme.addedText.color)
          Text(verbatim: "−\(counts.removed)").foregroundStyle(theme.removedText.color)
        }
        .font(theme.codeFont(size: size * 0.92))
      }
      if let outcome = title.outcome {
        Text(verbatim: outcome)
          .font(theme.interfaceFont(size: size, weight: .semibold))
          .foregroundStyle(outcomeColor(state).color)
          .lineLimit(1)
      }
      if let detail = title.detail, !detail.isEmpty {
        Text(verbatim: detail)
          .font(theme.interfaceFont(size: size * 0.95))
          .foregroundStyle(theme.secondaryText.color)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      if let duration = duration {
        Text(duration)
          .font(theme.interfaceFont(size: size * 0.9))
          .foregroundStyle(theme.secondaryText.color)
      }
      StateSymbol(state: state)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, appearance.density == .compact ? 6 : 9)
    .contentShape(Rectangle())
  }

  private var calls: [ToolCall] {
    switch block {
    case .entry(let entry): return entry.toolCall.map { [$0] } ?? []
    case .toolGroup(_, let calls): return calls.compactMap(\.toolCall)
    }
  }

  private var lineCounts: (added: Int, removed: Int)? {
    let edits = calls.filter { $0.kind == .edit || $0.kind == .create }
    guard !edits.isEmpty, edits.count == calls.count else { return nil }
    let added = edits.reduce(0) { $0 + ($1.facts.addedLines ?? 0) }
    let removed = edits.reduce(0) { $0 + ($1.facts.removedLines ?? 0) }
    return added + removed > 0 ? (added, removed) : nil
  }

  private var duration: String? {
    guard calls.count == 1, let duration = calls[0].facts.duration,
      duration >= .milliseconds(500)
    else { return nil }
    return duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
  }

  @ViewBuilder
  private var details: some View {
    switch block {
    case .entry(let entry):
      if let call = entry.toolCall {
        ToolCallDetails(call: call, model: model)
          .padding(12)
      }
    case .toolGroup(_, let entries):
      VStack(alignment: .leading, spacing: 6) {
        ForEach(entries) { entry in
          ToolBlockView(block: .entry(entry), model: model)
        }
      }
      .padding(10)
    }
  }

  private func borderColor(_ state: ToolCallState) -> ThemeColor {
    switch state {
    case .failed: return theme.failure
    case .awaitingPermission: return theme.warning
    default: return theme.border
    }
  }

  private func outcomeColor(_ state: ToolCallState) -> ThemeColor {
    if calls.contains(where: { ($0.facts.tests?.failed ?? 0) > 0 }) { return theme.failure }
    switch state {
    case .failed: return theme.failure
    case .succeeded: return theme.success
    case .refused, .awaitingPermission: return theme.warning
    default: return theme.secondaryText
    }
  }

  private func accessibilityTitle(state: ToolCallState) -> String {
    let title = title
    let words = [title.title, title.outcome, StateSymbol.label(for: state)].compactMap { $0 }
    return words.joined(separator: ", ")
  }
}

/// The state of a call, as a symbol with a name.
struct StateSymbol: View {
  let state: ToolCallState
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    Group {
      switch state {
      case .running:
        ProgressView().controlSize(.small).tint(theme.accent.color)
      case .awaitingPermission:
        Image(systemName: "lock.fill").foregroundStyle(theme.warning.color)
      case .succeeded:
        Image(systemName: "checkmark").foregroundStyle(theme.success.color)
      case .failed:
        Image(systemName: "xmark.octagon.fill").foregroundStyle(theme.failure.color)
      case .refused:
        Image(systemName: "hand.raised.fill").foregroundStyle(theme.warning.color)
      case .interrupted:
        Image(systemName: "stop.circle").foregroundStyle(theme.secondaryText.color)
      }
    }
    .font(.system(size: 13, weight: .semibold))
    .frame(width: 18, height: 18)
    .help(Self.label(for: state))
  }

  static func label(for state: ToolCallState) -> String {
    switch state {
    case .running: return String(localized: "running", bundle: .module)
    case .awaitingPermission:
      return String(localized: "waiting for your permission", bundle: .module)
    case .succeeded: return String(localized: "succeeded", bundle: .module)
    case .failed: return String(localized: "failed", bundle: .module)
    case .refused: return String(localized: "not allowed", bundle: .module)
    case .interrupted: return String(localized: "interrupted", bundle: .module)
    }
  }
}

/// What a call was asked and what it gave back.
struct ToolCallDetails: View {
  let call: ToolCall
  var model: ConversationModel?
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize * 0.86
    VStack(alignment: .leading, spacing: 10) {
      switch call.kind {
      case .todo:
        todoList(size: size)
      case .plan:
        if let plan = call.parameter(.plan) { MarkdownView(text: plan) }
      case .question:
        question(size: size)
      case .image:
        ProducedImageView(call: call, model: model)
      default:
        parameters(size: size)
      }
      ForEach(Array(call.changes.enumerated()), id: \.offset) { _, change in
        DiffView(change: change)
      }
      if let output = call.output, !output.text.isEmpty, call.kind != .todo {
        outputView(output, size: size)
      }
    }
  }

  @ViewBuilder
  private func parameters(size: Double) -> some View {
    // The path of an edit is the header of its diff already.
    let shown = call.parameters.filter {
      ![.todo, .plan].contains($0.key) && !($0.key == .path && !call.changes.isEmpty)
    }
    if !shown.isEmpty {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
        ForEach(Array(shown.enumerated()), id: \.offset) { _, parameter in
          GridRow {
            Text(Self.name(of: parameter.key))
              .font(theme.interfaceFont(size: size, weight: .medium))
              .foregroundStyle(theme.secondaryText.color)
            Text(verbatim: parameter.value)
              .font(theme.codeFont(size: size))
              .foregroundStyle(theme.text.color)
              .textSelection(.enabled)
              .lineLimit(12)
          }
        }
      }
    }
  }

  private func outputView(_ output: ToolOutput, size: Double) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ScrollView([.horizontal, .vertical]) {
        Text(verbatim: output.text)
          .font(theme.codeFont(size: size))
          .foregroundStyle(output.isError ? theme.failure.color : theme.codeText.color)
          .textSelection(.enabled)
          .fixedSize()
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)
      .background(theme.codeBackground.color)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      if output.omittedByteCount > 0 {
        Text(
          "\(ByteCountFormatter.string(fromByteCount: Int64(output.omittedByteCount), countStyle: .file)) left out of the middle",
          bundle: .module, comment: "An amount of text, such as 3 MB."
        )
        .font(theme.interfaceFont(size: size * 0.95))
        .foregroundStyle(theme.secondaryText.color)
      }
    }
  }

  private func todoList(size: Double) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(call.parameters.filter { $0.key == .todo }.enumerated()), id: \.offset) {
        _, parameter in
        let parts = parameter.value.split(separator: "\t", maxSplits: 1).map(String.init)
        let status = parts.first ?? ""
        let text = parts.count > 1 ? parts[1] : ""
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(
            systemName: status == "completed"
              ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted" : "circle"
          )
          .foregroundStyle(status == "completed" ? theme.success.color : theme.secondaryText.color)
          .accessibilityLabel(
            status == "completed"
              ? Text("Done", bundle: .module)
              : status == "in_progress"
                ? Text("In progress", bundle: .module) : Text("To do", bundle: .module))
          Text(verbatim: text)
            .font(theme.messageFont(size: size / 0.86))
            .strikethrough(status == "completed")
            .foregroundStyle(status == "completed" ? theme.secondaryText.color : theme.text.color)
        }
      }
    }
  }

  private func question(size: Double) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(call.parameters.enumerated()), id: \.offset) { _, parameter in
        if parameter.key == .question {
          Text(verbatim: parameter.value)
            .font(theme.messageFont(size: size / 0.86).weight(.semibold))
            .foregroundStyle(theme.text.color)
        } else {
          Label {
            Text(verbatim: parameter.value).foregroundStyle(theme.text.color)
          } icon: {
            Image(systemName: "circle").foregroundStyle(theme.secondaryText.color)
          }
          .font(theme.messageFont(size: size / 0.86))
        }
      }
    }
  }

  static func name(of key: ToolParameter.Key) -> LocalizedStringResource {
    switch key {
    case .command: return LocalizedStringResource("Command", bundle: .module)
    case .path: return LocalizedStringResource("Path", bundle: .module)
    case .pattern: return LocalizedStringResource("Pattern", bundle: .module)
    case .query: return LocalizedStringResource("Query", bundle: .module)
    case .url: return LocalizedStringResource("URL", bundle: .module)
    case .server: return LocalizedStringResource("Server", bundle: .module)
    case .tool: return LocalizedStringResource("Tool", bundle: .module)
    case .arguments: return LocalizedStringResource("Arguments", bundle: .module)
    case .description: return LocalizedStringResource("Description", bundle: .module)
    case .prompt: return LocalizedStringResource("Prompt", bundle: .module)
    case .workingDirectory: return LocalizedStringResource("Folder", bundle: .module)
    case .lines: return LocalizedStringResource("Lines", bundle: .module)
    case .plan: return LocalizedStringResource("Plan", bundle: .module)
    case .question: return LocalizedStringResource("Question", bundle: .module)
    case .todo: return LocalizedStringResource("Task", bundle: .module)
    }
  }
}

/// A file's diff: two gutters of line numbers, added lines green, removed ones red, and the
/// file's name with a way to open it.
struct DiffView: View {
  let change: FileDiff
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize * 0.82
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(
          systemName: change.kind == .added
            ? "doc.badge.plus" : change.kind == .deleted ? "trash" : "doc"
        )
        .foregroundStyle(theme.secondaryText.color)
        Text(verbatim: change.fileName)
          .font(theme.interfaceFont(size: size, weight: .semibold))
        Text(verbatim: (change.path as NSString).deletingLastPathComponent)
          .font(theme.interfaceFont(size: size * 0.95))
          .foregroundStyle(theme.secondaryText.color)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        // Shown in the Finder, never opened: the path comes from the transcript, and opening an
        // application or a `.command` an agent was made to write would run it.
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)])
        } label: {
          Text("Show in Finder", bundle: .module).font(theme.interfaceFont(size: size))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent.color)
        .disabled(!FileManager.default.fileExists(atPath: change.path))
      }
      .foregroundStyle(theme.text.color)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      Rectangle().fill(theme.border.color).frame(height: 1)
      ScrollView(.horizontal, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(shownHunks.enumerated()), id: \.offset) { index, hunk in
            if index > 0 {
              Text(verbatim: "⋯")
                .font(theme.codeFont(size: size))
                .foregroundStyle(theme.secondaryText.color)
                .padding(.leading, 12)
            }
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
              row(line, size: size)
            }
          }
        }
        .padding(.vertical, 4)
      }
      .fixedSize(horizontal: false, vertical: true)
      if hiddenLineCount > 0 {
        Text("\(hiddenLineCount) more lines not shown", bundle: .module)
          .font(theme.interfaceFont(size: size))
          .foregroundStyle(theme.secondaryText.color)
          .padding(8)
      }
    }
    .background(theme.codeBackground.color)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.color))
  }

  /// Drawn at most: a view of thousands of lines, unfolded in a conversation, costs more than it
  /// tells. What is left is counted.
  static let shownLineLimit = 500

  private var shownHunks: [DiffHunk] {
    var remaining = Self.shownLineLimit
    var hunks: [DiffHunk] = []
    for hunk in change.hunks where remaining > 0 {
      var shown = hunk
      shown.lines = Array(hunk.lines.prefix(remaining))
      remaining -= shown.lines.count
      hunks.append(shown)
    }
    return hunks
  }

  private var hiddenLineCount: Int {
    let total = change.hunks.reduce(0) { $0 + $1.lines.count }
    return max(0, total - Self.shownLineLimit) + change.omittedLineCount
  }

  private func row(_ line: DiffLine, size: Double) -> some View {
    let (background, foreground, sign): (Color, Color, String) =
      switch line.kind {
      case .added: (theme.addedBackground.color, theme.addedText.color, "+")
      case .removed: (theme.removedBackground.color, theme.removedText.color, "−")
      case .context: (.clear, theme.codeText.color, " ")
      }
    return HStack(spacing: 0) {
      if appearance.showsDiffLineNumbers {
        Text(verbatim: line.oldNumber.map(String.init) ?? "")
          .frame(width: 38, alignment: .trailing)
          .foregroundStyle(theme.secondaryText.color)
        Text(verbatim: line.newNumber.map(String.init) ?? "")
          .frame(width: 38, alignment: .trailing)
          .foregroundStyle(theme.secondaryText.color)
      }
      Text(verbatim: sign).frame(width: 20)
      Text(verbatim: line.text.isEmpty ? " " : line.text)
        .fixedSize()
    }
    .font(theme.codeFont(size: size))
    .foregroundStyle(foreground)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(background)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      line.kind == .added
        ? Text("Added: \(line.text)", bundle: .module)
        : line.kind == .removed
          ? Text("Removed: \(line.text)", bundle: .module) : Text(verbatim: line.text))
  }
}

/// An image the agent generated: shown, and offered to the web view and the Finder.
struct ProducedImageView: View {
  let call: ToolCall
  let model: ConversationModel?
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let url = call.producedImage, let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel(Text(verbatim: call.parameter(.prompt) ?? url.lastPathComponent))
        HStack(spacing: 14) {
          if let open = model?.openInWebView {
            Button {
              open(url, false)
            } label: {
              Label {
                Text("Open in the Web View", bundle: .module)
              } icon: {
                Image(systemName: "globe")
              }
            }
          }
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          } label: {
            Text("Show in Finder", bundle: .module)
          }
        }
        .buttonStyle(.plain)
        .font(theme.interfaceFont(size: 12))
        .foregroundStyle(theme.accent.color)
      } else {
        Text("The image is no longer where the agent saved it.", bundle: .module)
          .font(theme.interfaceFont(size: 12))
          .foregroundStyle(theme.secondaryText.color)
      }
    }
  }
}
