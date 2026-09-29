import SwiftUI
import VibeApplication

/// A sub-agent the agent started (#180): what kind, what for, how it goes — then, unfolded, its
/// mission, what it did and what it answered.
///
/// The same block on its own, as a line of a group and inside another sub-agent's activity: its
/// unfolding is kept by the call it stands for, wherever it is drawn.
struct SubagentBlockView: View {
  let call: ToolCall
  let model: ConversationModel
  /// A line of a group, or a sub-agent of a sub-agent: drawn lighter.
  var isNested = false
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var run: SubagentRun { call.subagent ?? SubagentRun() }

  var body: some View {
    let _ = model.toggleRevision
    let isExpanded = model.isSubagentExpanded(call)
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
          model.setSubagentExpanded(!isExpanded, call: call)
        }
      } label: {
        SubagentHeader(call: call, isExpanded: isExpanded)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: SubagentPresentation.accessibilityLabel(for: call)))
      .accessibilityValue(
        isExpanded ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module)
      )
      .accessibilityHint(
        Text("Shows or hides its mission, its activity and its answer.", bundle: .module))

      if !call.state.isFinished {
        LastActions(run: run)
      }
      // Asked by the sub-agent while its activity is not read: answered on its block.
      if let request = model.request(for: call) {
        RequestActions(model: model, request: request, call: call)
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
      }
      if isExpanded {
        Rectangle().fill(theme.border.color).frame(height: 1)
        SubagentSections(call: call, model: model)
          .padding(12)
      }
    }
    .background(isNested ? theme.raised.color : theme.surface.color)
    .clipShape(RoundedRectangle(cornerRadius: isNested ? 8 : 10))
    .overlay(
      RoundedRectangle(cornerRadius: isNested ? 8 : 10)
        .stroke(
          SubagentPresentation.borderColor(call.state, theme: theme).color,
          lineWidth: call.state.severity >= 4 ? 1.5 : 1))
  }
}

/// The line that says which sub-agent, what for, and how it goes.
struct SubagentHeader: View {
  let call: ToolCall
  let isExpanded: Bool
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize * 0.9
    let run = call.subagent ?? SubagentRun()
    HStack(spacing: 9) {
      Image(systemName: "chevron.right")
        .font(.system(size: size * 0.75, weight: .semibold))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .foregroundStyle(theme.secondaryText.color)
      Image(systemName: "person.2")
        .foregroundStyle(theme.secondaryText.color)
        .frame(width: 20)
      if let type = run.type, !type.isEmpty {
        SubagentTypeCapsule(type: type)
      }
      Text(verbatim: SubagentPresentation.description(of: call))
        .font(theme.interfaceFont(size: size, weight: .semibold))
        .foregroundStyle(theme.text.color)
        .lineLimit(1)
        .truncationMode(.middle)
      if let outcome = SubagentPresentation.outcome(of: call) {
        Text(verbatim: outcome)
          .font(theme.interfaceFont(size: size, weight: .semibold))
          .foregroundStyle(SubagentPresentation.outcomeColor(call.state, theme: theme).color)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if run.mode == .background, !call.state.isFinished {
        Image(systemName: "hourglass")
          .foregroundStyle(theme.secondaryText.color)
          .help(Text("in the background", bundle: .module))
      }
      SubagentFigures(call: call)
        .font(theme.interfaceFont(size: size * 0.9))
        .foregroundStyle(theme.secondaryText.color)
      StateSymbol(state: call.state)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, appearance.density == .compact ? 6 : 9)
    .contentShape(Rectangle())
  }
}

/// `Explore`, `general-purpose`, a skill's name.
struct SubagentTypeCapsule: View {
  let type: String
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    Text(verbatim: type)
      .font(theme.interfaceFont(size: 11, weight: .semibold))
      .foregroundStyle(theme.secondaryText.color)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border.color))
      .fixedSize()
  }
}

/// "in the background · 2 min 14 s · 14 tools": the time runs while the sub-agent does.
struct SubagentFigures: View {
  let call: ToolCall

  var body: some View {
    if call.state.isFinished {
      Text(verbatim: SubagentPresentation.figures(of: call, now: Date()))
        .lineLimit(1)
        .fixedSize()
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(verbatim: SubagentPresentation.figures(of: call, now: context.date))
          .lineLimit(1)
          .fixedSize()
          .monospacedDigit()
      }
    }
  }
}

/// The last calls of a sub-agent at work, under its header even folded. Three lines are kept for
/// them from the start, so that the conversation does not move at each call.
struct LastActions: View {
  let run: SubagentRun
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  static let count = 3

  var body: some View {
    let size = appearance.textSize.pointSize * 0.8
    let actions = run.activityEntries.map { SubagentActivitySummary(entries: $0).lastActions } ?? []
    VStack(alignment: .leading, spacing: 3) {
      ForEach(actions, id: \.callID) { action in
        let title = ToolCallSummary.title(for: action)
        HStack(spacing: 7) {
          Image(systemName: title.symbolName)
            .frame(width: 14)
          Text(verbatim: title.title)
            .foregroundStyle(theme.text.color.opacity(0.85))
          if let detail = title.detail, !detail.isEmpty {
            Text(verbatim: detail)
          }
        }
        .lineLimit(1)
        .truncationMode(.middle)
      }
    }
    .font(theme.interfaceFont(size: size))
    .foregroundStyle(theme.secondaryText.color)
    .frame(
      maxWidth: .infinity, minHeight: Double(Self.count) * (size + 5), alignment: .topLeading
    )
    .padding(.leading, 51)
    .padding(.trailing, 12)
    .padding(.bottom, 9)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      actions.isEmpty
        ? Text("No action yet", bundle: .module)
        : Text(
          "Last actions: \(actions.map { ToolCallSummary.title(for: $0).title }.joined(separator: ", "))",
          bundle: .module))
  }
}

/// Mission, activity and answer, each folded on its own.
struct SubagentSections: View {
  let call: ToolCall
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  private var run: SubagentRun { call.subagent ?? SubagentRun() }

  var body: some View {
    let _ = model.toggleRevision
    VStack(alignment: .leading, spacing: 8) {
      mission
      activity
      answer
    }
  }

  @ViewBuilder private var mission: some View {
    if let prompt = call.parameter(.prompt), !prompt.isEmpty {
      SectionDisclosure(
        title: Text("Mission", bundle: .module),
        preview: SubagentPresentation.firstLine(of: prompt),
        isExpanded: model.isExpanded(
          id: ConversationModel.missionToggleID(call.callID), default: false)
      ) {
        model.setExpanded($0, for: ConversationModel.missionToggleID(call.callID))
      } content: {
        MarkdownView(text: prompt)
      }
    } else {
      sectionNote(
        Text("Mission", bundle: .module),
        Text("Not given by the agent", bundle: .module))
    }
  }

  @ViewBuilder private var activity: some View {
    if run.depth > SubagentRun.maximumShownDepth {
      sectionNote(
        Text("Activity", bundle: .module),
        Text("Not shown at this depth", bundle: .module))
    } else {
      SectionDisclosure(
        title: Text("Activity", bundle: .module),
        preview: SubagentPresentation.activitySummary(of: call),
        showsPreviewUnfolded: true,
        isExpanded: model.isExpanded(
          id: ConversationModel.activityToggleID(call.callID), default: false)
      ) {
        model.setSubagentActivityExpanded($0, callID: call.callID)
      } content: {
        SubagentActivityView(run: run, model: model)
      }
    }
  }

  @ViewBuilder private var answer: some View {
    if let failure = run.failure, !failure.isEmpty {
      Text(verbatim: failure)
        .font(theme.interfaceFont(size: appearance.textSize.pointSize * 0.9))
        .foregroundStyle(theme.failure.color)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    if let result = run.result, !result.isEmpty {
      SectionDisclosure(
        title: Text("Result", bundle: .module),
        preview: nil,
        isExpanded: model.isExpanded(
          id: ConversationModel.resultToggleID(call.callID), default: true)
      ) {
        model.setExpanded($0, for: ConversationModel.resultToggleID(call.callID))
      } content: {
        AgentTextView(text: result)
      }
    } else if call.state == .succeeded, run.activity == .notFound {
      Text("Its answer was not found", bundle: .module)
        .font(theme.interfaceFont(size: 12))
        .foregroundStyle(theme.secondaryText.color)
    } else if call.state == .succeeded, run.activity == .loading {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading its answer…", bundle: .module)
      }
      .font(theme.interfaceFont(size: 12))
      .foregroundStyle(theme.secondaryText.color)
    }
  }

  private func sectionNote(_ title: Text, _ note: Text) -> some View {
    HStack(spacing: 8) {
      title.fontWeight(.semibold).foregroundStyle(theme.text.color)
      note.italic()
    }
    .font(theme.interfaceFont(size: appearance.textSize.pointSize * 0.86))
    .foregroundStyle(theme.secondaryText.color)
    .padding(.leading, 18)
    .accessibilityElement(children: .combine)
  }
}

/// A title that folds what follows it.
struct SectionDisclosure<Content: View>: View {
  let title: Text
  let preview: String?
  /// A figure rather than an excerpt: still worth reading once unfolded.
  var showsPreviewUnfolded = false
  let isExpanded: Bool
  let setExpanded: (Bool) -> Void
  @ViewBuilder let content: () -> Content
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let size = appearance.textSize.pointSize * 0.86
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { setExpanded(!isExpanded) }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: size * 0.75, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 10)
          title.fontWeight(.semibold).foregroundStyle(theme.text.color)
          if let preview, !preview.isEmpty, !isExpanded || showsPreviewUnfolded {
            Text(verbatim: preview)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer(minLength: 0)
        }
        .font(theme.interfaceFont(size: size))
        .foregroundStyle(theme.secondaryText.color)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityValue(
        isExpanded ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module))
      if isExpanded {
        content()
          .padding(.leading, 18)
      }
    }
  }
}

/// A sub-agent's own conversation, laid out as the main one, beside a rule.
struct SubagentActivityView: View {
  let run: SubagentRun
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    switch run.activity {
    case .notFound:
      Text("Its activity was not found", bundle: .module)
        .font(theme.interfaceFont(size: 12))
        .foregroundStyle(theme.secondaryText.color)
    case .unread, .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading its activity…", bundle: .module)
      }
      .font(theme.interfaceFont(size: 12))
      .foregroundStyle(theme.secondaryText.color)
    case .read(let entries):
      if entries.isEmpty {
        Text("Nothing yet", bundle: .module)
          .font(theme.interfaceFont(size: 12))
          .foregroundStyle(theme.secondaryText.color)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.displayedBlocks(of: entries)) { block in
            BlockView(block: block, model: model, isNested: true)
          }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
          Rectangle().fill(theme.border.color).frame(width: 2)
        }
      }
    }
  }
}

/// Sub-agents started together: one line each, each unfolding on its own.
struct SubagentGroupView: View {
  let block: ConversationBlock
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let _ = model.toggleRevision
    let isExpanded = model.isExpanded(block)
    let calls = block.calls
    let state = block.toolState ?? .succeeded
    let size = appearance.textSize.pointSize * 0.9
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
          model.setExpanded(!isExpanded, for: block.id)
        }
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "chevron.right")
            .font(.system(size: size * 0.75, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(theme.secondaryText.color)
          Image(systemName: "person.2")
            .foregroundStyle(theme.secondaryText.color)
            .frame(width: 20)
          Text(verbatim: SubagentPresentation.groupTitle(calls))
            .font(theme.interfaceFont(size: size, weight: .semibold))
            .foregroundStyle(theme.text.color)
          Text(verbatim: SubagentPresentation.groupProgress(calls))
            .font(theme.interfaceFont(size: size))
            .foregroundStyle(theme.secondaryText.color)
          Spacer(minLength: 8)
          StateSymbol(state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, appearance.density == .compact ? 6 : 9)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        Text(
          verbatim: [SubagentPresentation.groupTitle(calls), SubagentPresentation.groupProgress(calls)]
            .joined(separator: ", ")))
      .accessibilityValue(
        isExpanded ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module))

      if isExpanded {
        Rectangle().fill(theme.border.color).frame(height: 1)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(calls, id: \.callID) { call in
            SubagentBlockView(call: call, model: model, isNested: true)
          }
        }
        .padding(10)
      }
    }
    .background(theme.surface.color)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          SubagentPresentation.borderColor(state, theme: theme).color,
          lineWidth: state.severity >= 4 ? 1.5 : 1))
  }
}

/// Over the composer, while sub-agents run (#180): one pill each, which brings its block into view.
/// A sub-agent that ends stays a moment, dimmed, then goes.
struct SubagentTray: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme

  static let shownPillCount = 4

  var body: some View {
    let items = model.trayItems
    let running = items.filter { !$0.hasEnded }.count
    HStack(spacing: 8) {
      Label {
        Text("\(running) running", bundle: .module)
      } icon: {
        Image(systemName: "person.2")
      }
      .font(theme.interfaceFont(size: 12, weight: .semibold))
      .foregroundStyle(theme.secondaryText.color)
      .fixedSize()
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(items.prefix(Self.shownPillCount)) { item in
            SubagentPill(item: item, model: model)
          }
          if items.count > Self.shownPillCount {
            Menu {
              ForEach(items.dropFirst(Self.shownPillCount)) { item in
                Button {
                  model.revealSubagent(item.call.callID)
                } label: {
                  Text(verbatim: SubagentPresentation.description(of: item.call))
                }
              }
            } label: {
              Text(verbatim: "+\(items.count - Self.shownPillCount)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(
              Text("\(items.count - Self.shownPillCount) more sub-agents", bundle: .module))
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border.color))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Sub-agents running", bundle: .module))
    .onChange(of: items.filter(\.hasEnded).map(\.id)) { before, after in
      for id in after where !before.contains(id) {
        guard let item = items.first(where: { $0.id == id }) else { continue }
        var said = AttributedString(
          String(
            localized:
              "Sub-agent \(SubagentPresentation.description(of: item.call)) \(StateSymbol.label(for: item.call.state))",
            bundle: .module))
        // Said once, after what is being read: the end of a sub-agent does not interrupt.
        said.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(said).post()
      }
    }
  }
}

struct SubagentPill: View {
  let item: SubagentTrayItem
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    let call = item.call
    let run = call.subagent ?? SubagentRun()
    Button {
      model.revealSubagent(call.callID)
    } label: {
      HStack(spacing: 6) {
        if item.hasEnded || call.state == .awaitingPermission {
          StateSymbol(state: call.state).scaleEffect(0.8)
        } else if run.mode == .background {
          Image(systemName: "hourglass").foregroundStyle(theme.secondaryText.color)
        } else {
          ProgressView().controlSize(.mini)
        }
        if let type = run.type, !type.isEmpty {
          Text(verbatim: type)
            .fontWeight(.semibold)
            .foregroundStyle(theme.secondaryText.color)
        }
        Text(verbatim: SubagentPresentation.description(of: call))
          .foregroundStyle(theme.text.color)
          .lineLimit(1)
        if !item.hasEnded {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: SubagentPresentation.elapsed(of: call, now: context.date) ?? "")
              .monospacedDigit()
              .foregroundStyle(theme.secondaryText.color)
          }
        }
      }
      .font(theme.interfaceFont(size: 12))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(theme.surface.color, in: Capsule())
      .overlay(
        Capsule().stroke(
          call.state == .awaitingPermission ? theme.warning.color : theme.border.color))
      .opacity(item.hasEnded ? 0.6 : 1)
      .fixedSize()
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: SubagentPresentation.lastActionHelp(of: call)))
    .accessibilityLabel(Text(verbatim: SubagentPresentation.accessibilityLabel(for: call)))
    .accessibilityHint(Text("Shows the sub-agent in the conversation.", bundle: .module))
  }
}

/// The words of a sub-agent, the same on its block, its pill and in VoiceOver.
@MainActor
enum SubagentPresentation {
  static func firstLine(of text: String) -> String {
    let line =
      text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return line.trimmingCharacters(in: .whitespaces)
  }

  static func description(of call: ToolCall) -> String {
    call.parameter(.description) ?? call.summary ?? call.subagent?.type
      ?? String(localized: "Sub-agent", bundle: .module)
  }

  /// How it ended, when that deserves words.
  static func outcome(of call: ToolCall) -> String? {
    switch call.state {
    case .failed: return String(localized: "failed", bundle: .module)
    case .awaitingPermission:
      return String(localized: "waiting for your permission", bundle: .module)
    case .interrupted:
      return call.subagent?.result == nil
        ? String(localized: "stopped without an answer", bundle: .module)
        : String(localized: "stopped", bundle: .module)
    case .refused: return String(localized: "not allowed", bundle: .module)
    default: return nil
    }
  }

  static func elapsed(of call: ToolCall, now: Date) -> String? {
    guard let started = call.subagent?.startedAt else { return nil }
    return format(.seconds(max(0, Int(now.timeIntervalSince(started)))))
  }

  static func format(_ duration: Duration) -> String {
    duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
  }

  /// "in the background · 2m 14s · 14 tools" while it runs; "1m 2s · 9 tools" once done.
  static func figures(of call: ToolCall, now: Date) -> String {
    let run = call.subagent ?? SubagentRun()
    var parts: [String] = []
    if !call.state.isFinished {
      if run.mode == .background {
        parts.append(String(localized: "in the background", bundle: .module))
      }
      if let elapsed = elapsed(of: call, now: now) { parts.append(elapsed) }
    } else if let duration = run.usage?.duration {
      parts.append(format(duration))
    }
    if run.taskCount > 1 {
      parts.append(String(localized: "\(run.taskCount) tasks", bundle: .module))
    }
    let tools =
      call.state.isFinished
      ? run.usage?.toolUses ?? run.activityEntries.map { SubagentActivitySummary(entries: $0).toolCount }
      : run.activityEntries.map { SubagentActivitySummary(entries: $0).toolCount }
    if let tools {
      parts.append(String(localized: "\(tools) tools", bundle: .module))
    }
    return parts.joined(separator: " · ")
  }

  /// The folded activity: "14 tools · 2 files edited" once read, what the CLI counted otherwise.
  static func activitySummary(of call: ToolCall) -> String? {
    let run = call.subagent ?? SubagentRun()
    if let entries = run.activityEntries {
      let summary = SubagentActivitySummary(entries: entries)
      var parts = [String(localized: "\(summary.toolCount) tools", bundle: .module)]
      if summary.editedFileCount > 0 {
        parts.append(String(localized: "\(summary.editedFileCount) files edited", bundle: .module))
      }
      return parts.joined(separator: " · ")
    }
    return run.usage?.toolUses.map { String(localized: "\($0) tools", bundle: .module) }
  }

  static func groupTitle(_ calls: [ToolCall]) -> String {
    String(localized: "\(calls.count) sub-agents", bundle: .module)
  }

  static func groupProgress(_ calls: [ToolCall]) -> String {
    let done = calls.filter { $0.state.isFinished }.count
    return String(localized: "\(done) done", bundle: .module)
  }

  static func lastActionHelp(of call: ToolCall) -> String {
    guard let entries = call.subagent?.activityEntries,
      let last = SubagentActivitySummary(entries: entries).lastActions.last
    else { return description(of: call) }
    let title = ToolCallSummary.title(for: last)
    return String(localized: "Last action: \(title.title)", bundle: .module)
  }

  static func accessibilityLabel(for call: ToolCall) -> String {
    let run = call.subagent ?? SubagentRun()
    var parts = [String(localized: "Sub-agent", bundle: .module)]
    if let type = run.type { parts.append(type) }
    parts.append(description(of: call))
    parts.append(outcome(of: call) ?? StateSymbol.label(for: call.state))
    let figures = figures(of: call, now: Date())
    if !figures.isEmpty { parts.append(figures) }
    return parts.joined(separator: ", ")
  }

  static func borderColor(_ state: ToolCallState, theme: ConversationTheme) -> ThemeColor {
    switch state {
    case .failed: return theme.failure
    case .awaitingPermission: return theme.warning
    default: return theme.border
    }
  }

  static func outcomeColor(_ state: ToolCallState, theme: ConversationTheme) -> ThemeColor {
    switch state {
    case .failed: return theme.failure
    case .awaitingPermission, .refused: return theme.warning
    default: return theme.secondaryText
    }
  }
}
