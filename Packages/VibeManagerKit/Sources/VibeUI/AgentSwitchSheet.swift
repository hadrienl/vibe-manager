import SwiftUI
import VibeApplication
import VibeDomain

/// Moves a session to another agent or model.
///
/// Everything the switch will do is on this sheet before it is done: which agent is stopped,
/// whether the conversation goes on, and the summary the new agent is handed, editable.
struct AgentSwitchSheet: View {
  @Bindable var model: AgentSwitchModel
  let confirm: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        "Switch Agent — \(model.sessionName)", bundle: .module,
        comment: "Title of the Switch Agent sheet: the session's name."
      )
      .font(.headline)

      LabeledContent {
        Group {
          if model.stopsRunningAgent {
            Text(
              "\(model.currentLabel) — running", bundle: .module,
              comment: "The session's current agent and model, which is running.")
          } else {
            Text(model.currentLabel)
          }
        }
        .foregroundStyle(.secondary)
      } label: {
        Text("Now", bundle: .module, comment: "The agent the session runs now.")
      }

      agentField
      modelField

      if let warning = model.stopWarning {
        notice(warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
      }
      notice(model.continuityNotice, symbol: "info.circle", tint: .secondary)

      if model.offersResumeRetry {
        // Off by default: what failed is not retried unless asked. Worth asking when the model
        // was what the agent refused, and switching it is precisely the fix.
        Toggle(isOn: $model.retriesFailedResume) {
          Text("Try resuming the conversation anyway", bundle: .module)
        }
        .toggleStyle(.checkbox)
        .help(
          Text(
            """
            Worth trying when the previous model is what the agent refused, rather than the \
            conversation itself.
            """,
            bundle: .module))
      }

      if model.handover == .summary {
        summaryField
      }

      HStack {
        Spacer()
        Button(role: .cancel, action: cancel) {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        // ⌘↩ rather than ↩: the return key belongs to the summary being edited.
        Button(action: confirm) {
          Text(model.confirmTitle)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSwitch)
      }
    }
    .padding(20)
    .frame(width: 600)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.accessibilityDescription)
  }

  private var agentField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Switch to", bundle: .module, comment: "Heads the list of agents to switch to.")
        .font(.subheadline.weight(.medium))
      if model.agents.isEmpty {
        Group {
          if model.isLoadingAgents {
            Text("Looking for coding agents…", bundle: .module)
          } else {
            Text("No coding agent was detected on this Mac.", bundle: .module)
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      ForEach(model.agents) { agent in
        AgentChoiceRow(
          agent: agent,
          isSelected: agent.id.rawValue == model.providerID,
          select: { Task { await model.select(agent: agent.id.rawValue) } }
        )
      }
      Button {
        Task { await model.refreshAgents(forceRefresh: true) }
      } label: {
        Text("Detect again", bundle: .module)
      }
      .controlSize(.small)
      .disabled(model.isLoadingAgents)
    }
  }

  private var modelField: some View {
    LabeledContent {
      Picker(
        selection: Binding(get: { model.modelID }, set: { model.select(model: $0) })
      ) {
        Text("Default model of the agent", bundle: .module).tag(String?.none)
        ForEach(model.models) { available in
          Text(available.displayName).tag(String?.some(available.id))
        }
        // The model the session runs stays choosable even when the catalogue no longer lists it.
        if let modelID = model.modelID, !model.models.contains(where: { $0.id == modelID }) {
          Text(modelID).tag(String?.some(modelID))
        }
      } label: {
        Text("Model", bundle: .module, comment: "The model of a coding agent.")
      }
      .labelsHidden()
      .frame(maxWidth: 280, alignment: .leading)
      .disabled(model.models.isEmpty && model.modelID == nil)
    } label: {
      Text("Model", bundle: .module, comment: "The model of a coding agent.")
    }
  }

  private var summaryField: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(
          "Summary handed to \(model.targetName)", bundle: .module,
          comment: "Heads the summary the new agent is started with: its name."
        )
        .font(.subheadline.weight(.medium))
        Spacer()
        Text(sizeLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(model.summaryOverflow > 0 ? Color.red : .secondary)
          .accessibilityLabel(sizeAccessibilityLabel)
        Button {
          model.regenerateSummary()
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!model.isSummaryEdited)
        .help(Text("Regenerate the summary, dropping your edits", bundle: .module))
        .accessibilityLabel(Text("Regenerate the summary", bundle: .module))
      }
      TextEditor(text: $model.summaryText)
        .font(.system(.callout, design: .monospaced))
        .frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityLabel(
          Text(
            "Summary sent to \(model.targetName)", bundle: .module,
            comment: "VoiceOver: the summary's editor, and the agent it is sent to."))
      if model.summaryOverflow > 0 {
        Text(
          """
          \(Self.size(model.summaryOverflow)) over what an agent can be started with. Shorten \
          the summary.
          """,
          bundle: .module, comment: "A size, formatted: “120 bytes”, “1.5 KiB”."
        )
        .font(.caption)
        .foregroundStyle(.red)
      } else if model.generatedSummary?.isTruncated == true, !model.isSummaryEdited {
        Text("This summary was shortened to fit what the agent accepts.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let leftOut = model.leftOutNotes, !model.isSummaryEdited {
        Text(leftOut)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func notice(_ text: String, symbol: String, tint: Color) -> some View {
    Label {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
        .foregroundStyle(tint)
    }
    .font(.callout)
  }

  private var sizeLabel: String {
    String(
      localized:
        "\(Self.size(model.summaryByteCount)) of \(Self.size(AgentPromptLimits.argumentByteLimit))",
      bundle: .module, comment: "The summary's size, then the most an agent accepts.")
  }

  private var sizeAccessibilityLabel: String {
    model.summaryOverflow > 0
      ? String(
        localized: "Summary too long by \(Self.size(model.summaryOverflow))", bundle: .module,
        comment: "VoiceOver: a size, formatted.")
      : String(
        localized: "Summary uses \(sizeLabel)", bundle: .module,
        comment: "VoiceOver: “120 bytes of 96.0 KiB”.")
  }

  static func size(_ bytes: Int) -> String {
    guard bytes >= 1_024 else { return String(localized: "\(bytes) bytes", bundle: .module) }
    let kibibytes = (Double(bytes) / 1_024).formatted(
      .number.precision(.fractionLength(1)).grouping(.never))
    return String(
      localized: "\(kibibytes) KiB", bundle: .module, comment: "A size in kibibytes: “1.5 KiB”.")
  }
}
