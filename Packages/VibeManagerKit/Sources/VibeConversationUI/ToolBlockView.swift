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
      .accessibilityLabel(Self.accessibilityTitle(of: block))
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
    .clipShape(RoundedRectangle(cornerRadius: theme.layout.blockRadius))
    .overlay(
      RoundedRectangle(cornerRadius: theme.layout.blockRadius)
        .stroke(borderColor(state).color, lineWidth: state.severity >= 4 ? 1.5 : 1))
  }

  private var title: ToolCallTitle { Self.title(of: block) }

  static func title(of block: ConversationBlock) -> ToolCallTitle {
    switch block {
    case .entry(let entry):
      return entry.toolCall.map { ToolCallSummary.title(for: $0) }
        ?? ToolCallTitle(symbolName: "wrench.and.screwdriver", title: "")
    case .toolGroup(_, let calls), .subagentGroup(_, let calls):
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

  private var calls: [ToolCall] { block.calls }

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
        VStack(alignment: .leading, spacing: 12) {
          ToolCallDetails(call: call, model: model)
          if let request = model.request(for: call) {
            RequestActions(model: model, request: request, call: call)
          }
        }
        .padding(12)
      }
    case .toolGroup(_, let entries), .subagentGroup(_, let entries):
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

  /// What the block did, to whom, and how it ended: its header as VoiceOver reads it, and its
  /// name in the rotors (#232). A group says its targets — the commands, the files — and a group
  /// of sub-agents what they were asked; the state is said once, not again after an outcome
  /// that already says it.
  static func accessibilityTitle(of block: ConversationBlock) -> String {
    var words: [String]
    var outcome: String?
    if case .subagentGroup(_, let runs) = block {
      let calls = runs.compactMap(\.toolCall)
      let failed = calls.filter {
        if case .failed = $0.state { return true }
        return false
      }
      words = [
        ListFormatter.localizedString(
          byJoining: (failed.isEmpty ? calls : failed).map(SubagentPresentation.description(of:)))
      ]
    } else {
      let title = title(of: block)
      outcome = title.outcome
      words = [title.title, title.detail, title.outcome].compactMap { $0 }
    }
    words.removeAll(where: \.isEmpty)
    // Said once: not again after an outcome that already says it — « 2 failed », « failed ».
    let state = StateSymbol.label(for: block.toolState ?? .succeeded)
    if outcome?.localizedCaseInsensitiveContains(state) != true {
      words.append(state)
    }
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
            if parameter.key == .url, let url = MarkdownDocument.safeLink(parameter.value) {
              // The address a tool fetched, opened as any link of the conversation (#186).
              Text(Self.link(url))
                .font(theme.codeFont(size: size))
                .tint(theme.accent.color)
                .textSelection(.enabled)
                .lineLimit(12)
                .contextMenu { LinkMenuButtons(url: url) }
            } else {
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
  }

  private static func link(_ url: URL) -> AttributedString {
    var text = AttributedString(url.absoluteString)
    text.link = url
    return text
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
      .clipShape(RoundedRectangle(cornerRadius: theme.layout.innerRadius))
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

  @ViewBuilder
  private func question(size: Double) -> some View {
    if let model, let request = model.request(for: call), let questions = request.questions {
      AnswerableQuestions(model: model, request: request, questions: questions, size: size)
    } else {
      AskedQuestionsView(questions: AskedQuestion.all(in: call), size: size)
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
    case .answer: return LocalizedStringResource("Answer", bundle: .module)
    case .multipleChoices:
      return LocalizedStringResource("Several Choices", bundle: .module)
    case .question: return LocalizedStringResource("Question", bundle: .module)
    case .preview: return LocalizedStringResource("Preview", bundle: .module)
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
    .clipShape(RoundedRectangle(cornerRadius: theme.layout.innerRadius))
    .overlay(RoundedRectangle(cornerRadius: theme.layout.innerRadius).stroke(theme.border.color))
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
          .clipShape(RoundedRectangle(cornerRadius: theme.layout.innerRadius))
          .accessibilityLabel(Text(verbatim: call.parameter(.prompt) ?? url.lastPathComponent))
        HStack(spacing: 14) {
          if let open = model?.openInWebView {
            Button {
              // Opens outside: nothing — the session's web view shows the image's address.
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

/// Questions as the transcript tells them: their options, and once answered, the ones chosen —
/// or the user's own words.
struct AskedQuestionsView: View {
  let questions: [AskedQuestion]
  let size: Double
  @State private var highlighted: [Int: Int] = [:]
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: question.text)
            .font(theme.messageFont(size: size / 0.86).weight(.semibold))
            .foregroundStyle(theme.text.color)
          PreviewedOptions(
            previews: question.options.indices.map { question.previews[$0] },
            chosen: question.options.firstIndex { question.chosen.contains($0) },
            highlighted: $highlighted[index], size: size
          ) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { option, label in
              self.option(label, of: question)
                .onHover { if $0 { highlighted[index] = option } }
            }
          }
          if let other = question.otherAnswer {
            Label {
              Text(verbatim: other).foregroundStyle(theme.text.color).fontWeight(.semibold)
            } icon: {
              Image(systemName: "text.bubble.fill").foregroundStyle(theme.accent.color)
            }
            .font(theme.messageFont(size: size / 0.86))
            .textSelection(.enabled)
          }
        }
      }
    }
  }

  private func option(_ label: String, of question: AskedQuestion) -> some View {
    let isChosen = question.chosen.contains(label)
    return Label {
      Text(verbatim: label)
        .foregroundStyle(isChosen ? theme.text.color : theme.secondaryText.color)
        .fontWeight(isChosen ? .semibold : nil)
    } icon: {
      Image(systemName: question.symbol(chosen: isChosen))
        .foregroundStyle(isChosen ? theme.accent.color : theme.secondaryText.color)
    }
    .font(theme.messageFont(size: size / 0.86))
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }
}

/// A question's options, and beside them one preview at a time, as Claude Code draws them: the
/// option pointed at, else the one chosen, else the first that has one. Without previews, the
/// options alone.
struct PreviewedOptions<Options: View>: View {
  let previews: [String?]
  let chosen: Int?
  @Binding var highlighted: Int?
  let size: Double
  @ViewBuilder let options: Options
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    if let shown = AgentQuestion.previewedOption(
      previews: previews, highlighted: highlighted, chosen: chosen)
    {
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) { options }
          .frame(width: 260, alignment: .leading)
        // Every preview laid out, one visible: the block keeps the size of the largest, and what
        // follows it does not move as the pointer goes from one option to the next.
        ZStack(alignment: .topLeading) {
          ForEach(Array(previews.enumerated()), id: \.offset) { option, preview in
            self.preview(preview)
              .opacity(option == shown ? 1 : 0)
              .allowsHitTesting(option == shown)
              .accessibilityHidden(option != shown)
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 4) { options }
    }
  }

  @ViewBuilder
  private func preview(_ text: String?) -> some View {
    if let text {
      OptionPreview(text: DisplaySafeText.visible(text), size: size)
    } else {
      Text("No preview for this option", bundle: .module)
        .font(theme.interfaceFont(size: size * 0.95))
        .foregroundStyle(theme.secondaryText.color)
        .padding(8)
    }
  }
}

/// The questions the agent waits on, answered where they are asked: an option is a click, a free
/// answer is the composer's (#40, #41).
struct AnswerableQuestions: View {
  let model: ConversationModel
  let request: ConversationRequest
  let questions: [AgentQuestion]
  let size: Double
  @State private var highlighted: [Int: Int] = [:]
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        VStack(alignment: .leading, spacing: 4) {
          if let header = question.header, questions.count > 1 {
            Text(verbatim: DisplaySafeText.visible(header))
              .font(theme.interfaceFont(size: size * 0.9, weight: .semibold))
              .foregroundStyle(theme.secondaryText.color)
          }
          Text(verbatim: DisplaySafeText.visible(question.text))
            .font(theme.messageFont(size: size / 0.86).weight(.semibold))
            .foregroundStyle(theme.text.color)
            .fixedSize(horizontal: false, vertical: true)
          PreviewedOptions(
            previews: question.options.map(\.preview),
            chosen: question.options.indices.first {
              model.isChosen(option: $0, ofQuestion: index)
            },
            highlighted: $highlighted[index], size: size
          ) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { option, choice in
              optionButton(
                choice, option: option, question: index,
                isMultiple: question.allowsMultipleChoices,
                isEnabled: request.canChoose(in: question)
              )
              .onHover { if $0 { highlighted[index] = option } }
            }
          }
        }
      }
      if !request.answersAtOnce {
        Button {
          model.sendChoices()
        } label: {
          Text("Send Answers", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent.color)
        .disabled(!model.canSendChoices)
      }
    }
  }

  private func optionButton(
    _ choice: AgentQuestion.Option, option: Int, question: Int, isMultiple: Bool, isEnabled: Bool
  ) -> some View {
    let isChosen = model.isChosen(option: option, ofQuestion: question)
    let symbol =
      isMultiple
      ? (isChosen ? "checkmark.square.fill" : "square")
      : (isChosen ? "largecircle.fill.circle" : "circle")
    return Button {
      model.choose(option: option, ofQuestion: question)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(isChosen ? theme.accent.color : theme.secondaryText.color)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: DisplaySafeText.visible(choice.label))
            .font(theme.messageFont(size: size / 0.86))
            .foregroundStyle(theme.text.color)
          if let description = choice.description {
            Text(verbatim: DisplaySafeText.visible(description))
              .font(theme.interfaceFont(size: size * 0.95))
              .foregroundStyle(theme.secondaryText.color)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(OptionButtonStyle())
    .disabled(!isEnabled)
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }
}

/// What an option would look like, as the agent drew it: often a mockup in characters, kept in a
/// fixed-width font and never wrapped, so that its lines stay aligned.
struct OptionPreview: View {
  let text: String
  let size: Double
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      Text(verbatim: text)
        .font(theme.codeFont(size: size))
        .foregroundStyle(theme.codeText.color)
        .fixedSize()
        .textSelection(.enabled)
        .padding(8)
    }
    .fixedSize(horizontal: false, vertical: true)
    .background(theme.codeBackground.color)
    .clipShape(RoundedRectangle(cornerRadius: theme.layout.innerRadius))
    .overlay(RoundedRectangle(cornerRadius: theme.layout.innerRadius).stroke(theme.border.color))
    .accessibilityLabel(Text("Preview", bundle: .module))
    .accessibilityValue(Text(verbatim: text))
  }
}

private struct OptionButtonStyle: ButtonStyle {
  @Environment(\.conversationTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(theme.border.color.opacity(configuration.isPressed ? 0.8 : isHovered ? 0.45 : 0))
      )
      .opacity(isEnabled ? 1 : 0.55)
      .onHover { isHovered = isEnabled && $0 }
  }
}

/// The answers to a permission or a plan the agent waits on, given from the conversation as from
/// the palette (#40).
struct RequestActions: View {
  let model: ConversationModel
  let request: ConversationRequest
  let call: ToolCall
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // What would be allowed, unless the block above shows exactly that.
      if case .permission(let permission) = request.request.content,
        let subject = permission.subject,
        !ConversationModel.isAbout(call, subject)
      {
        Text(verbatim: DisplaySafeText.visible(subject))
          .font(theme.codeFont(size: 12))
          .foregroundStyle(theme.text.color)
          .textSelection(.enabled)
          .lineLimit(6)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(theme.codeBackground.color, in: RoundedRectangle(cornerRadius: 6))
      }
      // A dialog the agent only announced (#273): its own words are all there is to show.
      if case .inTerminal(let prompt) = request.request.content, let message = prompt.message {
        Text(verbatim: DisplaySafeText.visible(message))
          .font(theme.interfaceFont(size: 12.5))
          .foregroundStyle(theme.text.color)
          .textSelection(.enabled)
      }
      buttons
    }
  }

  private var buttons: some View {
    let answers = request.answers
    return HStack(spacing: 8) {
      switch request.request.content {
      case .permission(let permission):
        if answers.contains(.allowOnce) {
          Button {
            model.answer(.allowOnce)
          } label: {
            Text("Allow", bundle: .module, comment: "Allows what an agent asks, this once.")
          }
          .buttonStyle(.borderedProminent)
          .tint(theme.accent.color)
        }
        if answers.contains(.allowAlways), permission.alwaysAllow != nil {
          Button {
            model.answer(.allowAlways)
          } label: {
            Text("Always", bundle: .module, comment: "Allows what an agent asks, from now on.")
          }
        }
        if answers.contains(.deny) { denyButton }
      case .unreadable:
        if answers.contains(.deny) { denyButton }
      case .plan:
        if answers.contains(.approvePlan) {
          Menu {
            Button {
              model.answer(.approvePlan(.acceptEdits))
            } label: {
              Text("Approve, Accepting Edits", bundle: .module)
            }
            // Where Claude Code offers its auto mode, in place of accepting edits (#273).
            Button {
              model.answer(.approvePlan(.autoMode))
            } label: {
              Text("Approve in Auto Mode", bundle: .module)
            }
            Button {
              model.answer(.approvePlan(.reviewEdits))
            } label: {
              Text("Approve, Reviewing Each Edit", bundle: .module)
            }
          } label: {
            Text("Approve", bundle: .module, comment: "Approves an agent's plan.")
          }
          .fixedSize()
        }
        if answers.contains(.rejectPlan) {
          Button {
            model.answer(.rejectPlan)
          } label: {
            Text("Reject", bundle: .module, comment: "Rejects an agent's plan.")
          }
          .help(Text(Self.stopsTheTurn))
        }
      case .questions, .elicitation, .inTerminal:
        EmptyView()
      }
      if request.isSending {
        ProgressView().controlSize(.small)
      }
      if answers.isEmpty {
        Text("This request can only be answered in the terminal.", bundle: .module)
          .font(theme.interfaceFont(size: 11.5))
          .foregroundStyle(theme.secondaryText.color)
      }
    }
    .controlSize(.small)
    .disabled(request.isSending)
  }

  static let stopsTheTurn = LocalizedStringResource(
    "Also interrupts the agent's turn: it waits for your next message.", bundle: .module,
    comment: "What refusing a request does besides refusing.")

  private var denyButton: some View {
    Button {
      model.answer(.deny)
    } label: {
      Text("Refuse", bundle: .module, comment: "Refuses what an agent asks.")
    }
    .help(Text(Self.stopsTheTurn))
    .accessibilityHint(Text(Self.stopsTheTurn))
  }
}

/// A question of a call, read back from its parameters.
struct AskedQuestion: Equatable {
  var text: String
  var options: [String] = []
  /// Each option's preview, by its index.
  var previews: [Int: String] = [:]
  var allowsMultipleChoices = false
  var answer: String?

  static func all(in call: ToolCall) -> [AskedQuestion] {
    var questions: [AskedQuestion] = []
    for parameter in call.parameters {
      switch parameter.key {
      case .question: questions.append(AskedQuestion(text: parameter.value))
      case .multipleChoices where !questions.isEmpty:
        questions[questions.count - 1].allowsMultipleChoices = true
      case .arguments where !questions.isEmpty:
        questions[questions.count - 1].options.append(parameter.value)
      case .preview where !questions.isEmpty && !questions[questions.count - 1].options.isEmpty:
        let question = questions[questions.count - 1]
        questions[questions.count - 1].previews[question.options.count - 1] = parameter.value
      case .answer where !questions.isEmpty: questions[questions.count - 1].answer = parameter.value
      default: break
      }
    }
    return questions
  }

  /// The options the answer names: one label, or for several choices, labels joined by ", ".
  var chosen: Set<String> {
    guard let answer else { return [] }
    if options.contains(answer) { return [answer] }
    guard allowsMultipleChoices else { return [] }
    let parts = Set(answer.components(separatedBy: ", "))
    return parts.isSubset(of: options) ? parts : []
  }

  /// The user's own words, when the answer names no option.
  var otherAnswer: String? {
    guard let answer, !answer.isEmpty, chosen.isEmpty else { return nil }
    return answer
  }

  func symbol(chosen: Bool) -> String {
    allowsMultipleChoices
      ? (chosen ? "checkmark.square.fill" : "square")
      : (chosen ? "largecircle.fill.circle" : "circle")
  }
}
