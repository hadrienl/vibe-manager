import AppKit
import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

/// The agent of a session, in its status bar (#575): "Claude Code · Opus 5.5", before the effort,
/// which depends on it.
///
/// A native menu of two lines, `AgentMenu`. On top, the agent the session runs and its state,
/// with the history of its switches as its submenu. Below, "Switch To", with the models of each
/// agent as its submenu: one of them opens the Switch Agent sheet set on it. The side its
/// submenus open on, and where they line up, are macOS's.
///
/// The button looks like the effort's menu beside it; its menu is AppKit's, which gives its first
/// line a title in bold and each agent its logo.
struct SessionAgentMenu: View {
  let model: AppModel
  let session: WorkSession
  @Environment(\.statusBarDensity) private var density
  /// The agents and models to switch to, read when the menu is shown and when it opens.
  @State private var choices: AgentSwitchChoices?
  /// The button's own view, which the menu opens above.
  @State private var anchor = MenuAnchor.Holder()

  var body: some View {
    let names = AgentLabels(names: model.agentNames, models: choices?.modelNames ?? [:])
    let canSwitch = model.canSwitchAgent(session)
    let history = AgentHistoryPresentation(session: session, names: names)
    // The bar's step, or a narrower one when even that does not fit.
    ViewThatFits(in: .horizontal) {
      ForEach(density.andNarrower, id: \.self) { form in
        Button {
          openMenu(names: names, canSwitch: canSwitch)
        } label: {
          HStack(spacing: 8) {
            label(names: names, form: form)
            // A menu's own mark, as the effort's menu draws it.
            Image(systemName: "chevron.down")
              .font(.system(size: 8, weight: .semibold))
              .accessibilityHidden(true)
          }
        }
        .controlSize(.small)
        .fixedSize()
      }
    }
    .background(MenuAnchor(holder: anchor))
    .disabled(session.agent == nil || (!canSwitch && !history.hasChanges))
    // Outside the disabled menu, so that it is shown on the menu greyed out too.
    .instantTooltip(Text(verbatim: help(names: names, canSwitch: canSwitch)))
    .accessibilityLabel(
      Text("Agent", bundle: .module, comment: "The status bar's menu of the agent, for VoiceOver.")
    )
    .accessibilityValue(
      Text(
        verbatim: session.agent.map { names.label($0, separator: ", ") }
          ?? String(localized: "No agent recorded", bundle: .module))
    )
    .task(id: session.agent) { await readChoices() }
  }

  // MARK: - The button

  /// The button's label at a step of the bar: "Claude Code · Opus 5.5", the model alone, or the
  /// icon.
  @ViewBuilder
  private func label(names: AgentLabels, form: StatusBarDensity) -> some View {
    if let agent = session.agent {
      switch form {
      case .full:
        Text(verbatim: names.label(agent))
      case .model, .level, .gauge:
        // The agent's name when it runs its default model: there is no model to name.
        Text(verbatim: names.model(of: agent) ?? names.name(of: agent.providerID))
      case .icons:
        Image(systemName: "cpu")
      }
    } else if form == .icons {
      Image(systemName: "cpu")
    } else {
      Text("No agent recorded", bundle: .module)
    }
  }

  /// The full value, whatever the label leaves out, or why nothing can be chosen.
  private func help(names: AgentLabels, canSwitch: Bool) -> String {
    guard let agent = session.agent else {
      return String(localized: "This session was stored without an agent.", bundle: .module)
    }
    let label = names.label(agent)
    if canSwitch {
      return String(
        localized: "Agent: \(label)", bundle: .module,
        comment: "Help of the status bar's menu of the agent: its name and model.")
    }
    if session.status == .archived {
      return String(
        localized: "Agent: \(label). An archived session's agent cannot be switched.",
        bundle: .module,
        comment: "Help of the status bar's menu of the agent, for an archived session.")
    }
    return String(
      localized:
        "Agent: \(label). It can be switched once the session is done restarting, closing or being restored.",
      bundle: .module,
      comment:
        "Help of the status bar's menu of the agent, while the session restarts, closes or is restored."
    )
  }

  // MARK: - The menu

  /// Opens the menu above the button, as it is now; the agents are read again meanwhile, for the
  /// next time — an agent installed since is offered then.
  private func openMenu(names: AgentLabels, canSwitch: Bool) {
    let content = AgentMenuContent(
      session: session, names: names, choices: choices, state: stateSentence,
      canSwitch: canSwitch)
    let id = session.id
    let menu = AgentMenu.make(content) { [model] target in
      model.beginAgentSwitch(id, preselected: target)
    }
    Task { await readChoices() }
    guard let view = anchor.view else { return }
    let gap: CGFloat = 4
    // The menu's top left corner: above the button, on its left edge.
    let top = view.isFlipped ? -gap - menu.size.height : view.bounds.height + gap + menu.size.height
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: view)
  }

  /// The process's own state when it does not run — stopped, failed, starting — and otherwise
  /// whether the agent can be resumed.
  private var stateSentence: String {
    if let status = model.pane(for: session.id)?.status, status != .running {
      return status.label
    }
    return AgentHistoryPresentation.state(of: model.resolution(forID: session.id))
  }

  /// Opens the Switch Agent sheet set on `choice`, or on nothing: the switch itself is the
  /// sheet's, which says what will be stopped, resumed or handed over.
  static func open(
    _ choice: AgentSwitchChoices.Choice?, of id: SessionID, in model: AppModel
  ) {
    model.beginAgentSwitch(id, preselected: choice?.target)
  }

  private func readChoices() async {
    guard let registry = model.agents else { return }
    let read = await AgentSwitchChoices.read(from: registry)
    if read != choices { choices = read }
  }
}

/// What the history of a session's agents says (#575), in words: the menu's lines, and what
/// VoiceOver reads of each. Every agent the session had, newest first: each switch, the failed
/// ones included, then where it started.
@MainActor
struct AgentHistoryPresentation: Equatable {
  struct Entry: Equatable, Identifiable {
    enum ID: Hashable {
      case change(AgentChange.ID)
      case start
    }

    let id: ID
    /// "Codex · gpt-6.1 → Claude Code · Opus 5.5", "→ Opus 5.5 failed", "Started with …".
    let title: String
    /// When, and what was handed over, or why it failed.
    let detail: String
    let failed: Bool
    let spoken: String
  }

  let entries: [Entry]
  /// Whether the session ever switched, or tried to: its start alone is no history.
  let hasChanges: Bool

  init(session: WorkSession, names: AgentLabels) {
    var entries = session.agentHistory.reversed().map { Self.entry($0, names: names) }
    // The agent that first ran: the one the first real switch left, or the current one. A switch
    // made before the session ever ran does not count — the agent it left never started.
    let first = session.agentHistory.first(where: \.leftAgentThatRan)?.previous ?? session.agent
    if let first, let start = session.startedAt {
      let label = names.label(first)
      entries.append(
        Entry(
          id: .start,
          title: String(
            localized: "Started with \(label)", bundle: .module,
            comment: "The agent a session first ran: its name, and its model."),
          detail: Self.shown(start),
          failed: false,
          spoken: String(
            localized: "\(Self.spoken(start)), started with \(label)", bundle: .module,
            comment: "What VoiceOver says of a session's start: a date, then its first agent.")))
    }
    self.entries = entries
    hasChanges = !session.agentHistory.isEmpty
  }

  private static func entry(_ change: AgentChange, names: AgentLabels) -> Entry {
    let from = names.label(change.previous)
    let to = names.label(change.next)
    switch change.outcome {
    case .completed:
      let handover = handover(change.handover)
      return Entry(
        id: .change(change.id),
        title: "\(from) → \(to)",
        detail: "\(shown(change.date)) · \(handover)",
        failed: false,
        spoken: String(
          localized:
            "\(spoken(change.date)), switched from \(from) to \(to), \(handover)",
          bundle: .module,
          comment:
            "What VoiceOver says of an agent switch: a date, the agent left, the agent taken, and what was handed over."
        ))
    case .failed(let reason):
      return Entry(
        id: .change(change.id),
        title: String(
          localized: "→ \(to) failed", bundle: .module,
          comment: "A switch to this agent that failed."),
        detail: reason.isEmpty ? shown(change.date) : "\(shown(change.date)) · \(reason)",
        failed: true,
        spoken: String(
          localized: "\(spoken(change.date)), switch to \(to) failed. \(reason)",
          bundle: .module,
          comment: "What VoiceOver says of a failed agent switch: a date, the agent, and why."))
    }
  }

  /// Whether the agent can be resumed, or why not.
  static func state(of resolution: SessionAgentResolution?) -> String {
    switch resolution {
    case .ready:
      return String(localized: "Ready to resume.", bundle: .module)
    case .unavailable(let diagnostic):
      return diagnostic.summary
    case .unknownProvider(let providerID):
      return String(
        localized: "The provider \(providerID) is not installed in this build.", bundle: .module,
        comment: "An agent's identifier: claude-code, codex.")
    case .unassigned:
      return String(localized: "This session was stored without an agent.", bundle: .module)
    case .none:
      return String(localized: "Detection has not answered yet.", bundle: .module)
    }
  }

  static func handover(_ handover: AgentChange.Handover) -> String {
    switch handover {
    case .resumedConversation:
      return String(
        localized: "same conversation", bundle: .module,
        comment: "What an agent switch handed over: the conversation was resumed.")
    case .conversationHistory:
      return String(localized: "conversation history", bundle: .module)
    case .summary(let bytes, _, let wasEdited):
      let size = AgentSwitchSheet.size(bytes)
      return wasEdited
        ? String(
          localized: "edited summary, \(size)", bundle: .module,
          comment: "What an agent switch handed over: a size, “1.2 KiB”.")
        : String(
          localized: "summary, \(size)", bundle: .module,
          comment: "What an agent switch handed over: a size, “1.2 KiB”.")
    case .initialPrompt:
      return String(
        localized: "initial prompt", bundle: .module,
        comment: "What an agent switch handed over.")
    case .nothing:
      return String(
        localized: "nothing handed over", bundle: .module,
        comment: "What an agent switch handed over.")
    }
  }

  private static func shown(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func spoken(_ date: Date) -> String {
    date.formatted(date: .long, time: .shortened)
  }
}

/// How the menu names an agent and its model: the agent's name, and the model's as its catalogue
/// gives it — "Claude Code · Opus 5.5" — or its identifier when the catalogue does not list it.
struct AgentLabels: Equatable {
  let names: [String: String]
  /// Provider, then model identifier, to the model's name.
  var models: [String: [String: String]] = [:]

  func name(of providerID: String) -> String {
    AgentNaming.name(of: providerID, names: names)
  }

  /// `nil` for the agent's default model. An alias — `opus` — is named after the model it stands
  /// for, whatever its case.
  func model(of agent: SessionAgentConfiguration) -> String? {
    agent.modelID.map { id in
      let names = models[agent.providerID]
      return names?[id] ?? names?[id.lowercased()] ?? id
    }
  }

  func label(_ agent: SessionAgentConfiguration, separator: String = " · ") -> String {
    let name = name(of: agent.providerID)
    return model(of: agent).map { "\(name)\(separator)\($0)" } ?? name
  }
}

/// The view the agent's menu opens from: SwiftUI gives a button no view of its own.
struct MenuAnchor: NSViewRepresentable {
  @MainActor
  final class Holder {
    weak var view: NSView?
  }

  let holder: Holder

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    holder.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    holder.view = view
  }
}
