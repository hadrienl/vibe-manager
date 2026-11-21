import SwiftUI
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

/// What the status bar of a session's terminal and conversation shows beside its Close: the
/// agent (#575), the menu of reasoning effort (#411), the usage (#574), then the button of the
/// drawer.
struct SessionStatusAccessory: View {
  let model: AppModel
  let session: WorkSession

  var body: some View {
    let isRunning = model.launcher?.isRunning(session.id) ?? false
    StatusAccessoryStack {
      SessionAgentMenu(model: model, session: session)
        .statusBarItem("agent")
      EffortStatusMenu(model: model, session: session)
        .statusBarItem("effort")
      if let usage = model.usage {
        SessionUsageButton(
          usage: usage, session: session, isShown: model.selectedSessionID == session.id,
          agentNames: model.agentNames
        )
        .statusBarItem("usage")
      }
      if model.terminals != nil {
        DrawerStatusButton(model: model, session: session)
          .statusBarItem("drawer")
      }
    }
    // Read again when the agent or the process changes; a turn ending reads it too.
    .task(id: EffortRefresh(agent: session.agent, isRunning: isRunning)) {
      await model.refreshEffort(of: session.id)
    }
  }

  private struct EffortRefresh: Equatable {
    let agent: SessionAgentConfiguration?
    let isRunning: Bool
  }
}

/// The buttons beside the status bar's Close, served before its state text. The bar shares what
/// room is left evenly between them otherwise: the Usage label lost its cost with room to spare
/// beside a long state (#574). The text gives way first; the label narrows only when the bar runs
/// out of room.
struct StatusAccessoryStack<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 8) { content }
      .layoutPriority(1)
  }
}

/// The compact menu of the agent's reasoning effort: "Effort: High". Only at rest: a level given
/// during a turn would be typed into it.
struct EffortStatusMenu: View {
  let model: AppModel
  let session: WorkSession
  @Environment(\.statusBarDensity) private var density

  var body: some View {
    if let menu = model.effortMenu(for: session.id) {
      let isWorking: Bool =
        switch model.activity(for: session.id)?.activity {
        case .working, .awaitingUser: true
        case .idle, nil: false
        }
      // The bar's step, or a narrower one when even that does not fit.
      ViewThatFits(in: .horizontal) {
        ForEach(density.andNarrower, id: \.self) { form in
          Menu {
            levels(menu)
          } label: {
            Self.label(of: menu.current, form: form)
          }
          .controlSize(.small)
          .fixedSize()
        }
      }
      .disabled(!model.canChangeEffort(of: session.id))
      // Outside the disabled menu, so that it is shown on the menu greyed out too.
      .instantTooltip(
        isWorking
          ? Text(
            "The agent is working: its effort can be changed between two turns.", bundle: .module,
            comment: "Help of the status bar's menu of reasoning effort, greyed out during a turn.")
          : Text(
            "The agent's reasoning effort", bundle: .module,
            comment: "Help of the status bar's menu of reasoning effort.")
      )
      .accessibilityLabel(
        Text("Reasoning effort", bundle: .module, comment: "The status bar's menu, for VoiceOver.")
      )
      .accessibilityValue(
        menu.current.map(Self.name(of:))
          ?? Text(
            "Default", bundle: .module,
            comment: "The agent's own reasoning effort, in the status bar's menu."))
    }
  }

  private func levels(_ menu: SessionEffortMenu) -> some View {
    Picker(selection: selection(menu)) {
      if menu.offersDefault {
        Text(
          "Default", bundle: .module,
          comment: "The agent's own reasoning effort, in the status bar's menu."
        )
        .tag(Self.defaultTag)
      }
      ForEach(menu.levels, id: \.self) { level in
        Self.name(of: level).tag(level)
      }
    } label: {
      EmptyView()
    }
    .pickerStyle(.inline)
    .labelsHidden()
  }

  /// The menu's label at a step of the bar: "Effort: High", "High", or the gauge.
  @ViewBuilder
  static func label(of level: String?, form: StatusBarDensity) -> some View {
    switch form {
    case .full, .model:
      title(of: level)
    case .level, .gauge:
      level.map(name(of:))
        ?? Text(
          "Default", bundle: .module,
          comment: "The agent's own reasoning effort, in the status bar's menu.")
    case .icons:
      Image(systemName: "gauge.with.dots.needle.50percent")
    }
  }

  /// The tag of "Default": no level is an empty word.
  private static let defaultTag = ""

  private func selection(_ menu: SessionEffortMenu) -> Binding<String> {
    Binding {
      menu.current ?? Self.defaultTag
    } set: { level in
      model.setEffort(level == Self.defaultTag ? nil : level, for: session.id)
    }
  }

  /// A level as the menu lists it.
  static func name(of level: String) -> Text {
    switch level {
    case "minimal": Text("Minimal", bundle: .module, comment: "A level of reasoning effort.")
    case "low": Text("Low", bundle: .module, comment: "A level of reasoning effort.")
    case "medium": Text("Medium", bundle: .module, comment: "A level of reasoning effort.")
    case "high": Text("High", bundle: .module, comment: "A level of reasoning effort.")
    case "xhigh": Text("Extra High", bundle: .module, comment: "A level of reasoning effort.")
    case "max": Text("Maximum", bundle: .module, comment: "A level of reasoning effort.")
    case "ultra": Text("Ultra", bundle: .module, comment: "A level of reasoning effort.")
    default: Text(verbatim: level)
    }
  }

  /// The menu's own label, the level in force.
  static func title(of level: String?) -> Text {
    let comment: StaticString =
      "The status bar's menu of reasoning effort, with the level in force."
    switch level {
    case nil: return Text("Effort: Default", bundle: .module, comment: comment)
    case "minimal": return Text("Effort: Minimal", bundle: .module, comment: comment)
    case "low": return Text("Effort: Low", bundle: .module, comment: comment)
    case "medium": return Text("Effort: Medium", bundle: .module, comment: comment)
    case "high": return Text("Effort: High", bundle: .module, comment: comment)
    case "xhigh": return Text("Effort: Extra High", bundle: .module, comment: comment)
    case "max": return Text("Effort: Maximum", bundle: .module, comment: comment)
    case "ultra": return Text("Effort: Ultra", bundle: .module, comment: comment)
    case let level?:
      return Text(
        "Effort: \(level)", bundle: .module,
        comment:
          "The status bar's menu of reasoning effort, with a level the application has no name for."
      )
    }
  }
}
