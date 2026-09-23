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
      Text("Switch Agent — \(model.sessionName)")
        .font(.headline)

      LabeledContent("Now") {
        Text(model.currentLabel + (model.stopsRunningAgent ? " — running" : ""))
          .foregroundStyle(.secondary)
      }

      agentField
      modelField

      if let warning = model.stopWarning {
        notice(warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
      }
      notice(model.continuityNotice, symbol: "info.circle", tint: .secondary)

      if model.handover == .summary {
        summaryField
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        // ⌘↩ rather than ↩: the return key belongs to the summary being edited.
        Button(model.confirmTitle, action: confirm)
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
      Text("Switch to")
        .font(.subheadline.weight(.medium))
      if model.agents.isEmpty {
        Text(
          model.isLoadingAgents
            ? "Looking for coding agents…" : "No coding agent was detected on this Mac."
        )
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
      Button("Detect again") {
        Task { await model.refreshAgents(forceRefresh: true) }
      }
      .controlSize(.small)
      .disabled(model.isLoadingAgents)
    }
  }

  private var modelField: some View {
    LabeledContent("Model") {
      Picker(
        "Model",
        selection: Binding(get: { model.modelID }, set: { model.select(model: $0) })
      ) {
        Text("Default model of the agent").tag(String?.none)
        ForEach(model.models) { available in
          Text(available.displayName).tag(String?.some(available.id))
        }
        // The model the session runs stays choosable even when the catalogue no longer lists it.
        if let modelID = model.modelID, !model.models.contains(where: { $0.id == modelID }) {
          Text(modelID).tag(String?.some(modelID))
        }
      }
      .labelsHidden()
      .frame(maxWidth: 280, alignment: .leading)
      .disabled(model.models.isEmpty && model.modelID == nil)
    }
  }

  private var summaryField: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Summary handed to \(model.targetName)")
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
        .help("Regenerate the summary, dropping your edits")
        .accessibilityLabel("Regenerate the summary")
      }
      TextEditor(text: $model.summaryText)
        .font(.system(.callout, design: .monospaced))
        .frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityLabel("Summary sent to \(model.targetName)")
      if model.summaryOverflow > 0 {
        Text(
          """
          \(Self.size(model.summaryOverflow)) over what an agent can be started with. Shorten \
          the summary.
          """
        )
        .font(.caption)
        .foregroundStyle(.red)
      } else if model.generatedSummary?.isTruncated == true, !model.isSummaryEdited {
        Text("This summary was shortened to fit what the agent accepts.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
    "\(Self.size(model.summaryByteCount)) of \(Self.size(AgentPromptLimits.argumentByteLimit))"
  }

  private var sizeAccessibilityLabel: String {
    model.summaryOverflow > 0
      ? "Summary too long by \(Self.size(model.summaryOverflow))"
      : "Summary uses \(sizeLabel)"
  }

  static func size(_ bytes: Int) -> String {
    bytes < 1_024 ? "\(bytes) bytes" : String(format: "%.1f KiB", Double(bytes) / 1_024)
  }
}
