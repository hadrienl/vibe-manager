import SwiftUI
import VibeDomain

/// The usage of the selected session, in the inspector's Session pane.
///
/// What the application measured — running time, runs — is shown as is. What the CLI reported —
/// tokens — carries `≈` and its source. What nobody knows says why, and is never a zero.
struct SessionUsageSection: View {
  let session: WorkSession
  let usage: UsageModel
  let agentNames: [String: String]

  var body: some View {
    Section {
      if !usage.isTrackingEnabled {
        InspectorLine(label: Self.usageTitle, value: UsagePresentation.unavailable(.trackingOff))
      }
      let figures = usage.sessionUsage[session.id]
      InspectorLine(
        label: LocalizedStringResource(
          "Running time", bundle: .module, comment: "A session's usage: how long its agent ran."),
        value: figures.map { UsagePresentation.duration($0.total.runningTime) } ?? "—",
        help: UsagePresentation.runningTimeExplanation)
      InspectorLine(
        label: LocalizedStringResource(
          "Runs", bundle: .module,
          comment: "A session's usage: how many times its agent was started."),
        value: figures.map { UsagePresentation.runs($0.total.runs) } ?? "—")
      if let since = usage.runsRecordedSince, since > session.createdAt {
        Text(
          "Recorded since \(since.formatted(date: .abbreviated, time: .omitted)).",
          bundle: .module, comment: "The day runs started to be recorded."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      tokens(figures)
      InspectorLine(
        label: LocalizedStringResource(
          "Cost", bundle: .module, comment: "A session's usage: what it cost."),
        value: String(
          localized: "Not available", bundle: .module, comment: "A session's cost is unknown."),
        help: UsagePresentation.costExplanation)
    } header: {
      HStack {
        Text(Self.usageTitle)
        Spacer()
        if usage.isReading {
          ProgressView().controlSize(.mini)
            .accessibilityLabel(Text("Reading transcripts", bundle: .module))
        }
      }
    }
    .onAppear { usage.startWatching(session.id) }
    .onDisappear { usage.stopWatching(session.id) }
    // The inspector keeps this view when another session is selected.
    .onChange(of: session.id) { previous, next in
      usage.stopWatching(previous)
      usage.startWatching(next)
    }
  }

  private static var usageTitle: LocalizedStringResource {
    LocalizedStringResource("Usage", bundle: .module, comment: "A session's usage, heading.")
  }

  private static var tokensTitle: LocalizedStringResource {
    LocalizedStringResource(
      "Tokens", bundle: .module, comment: "A session's usage: the tokens its agent reported.")
  }

  @ViewBuilder
  private func tokens(_ figures: SessionUsage?) -> some View {
    if usage.sessionUsage[session.id] == nil {
      InspectorLine(label: Self.tokensTitle, value: "—", help: UsagePresentation.tokensExplanation)
    } else if let reason = usage.tokenUnavailability(for: session) {
      InspectorLine(
        label: Self.tokensTitle, value: UsagePresentation.unavailable(reason),
        help: UsagePresentation.tokensExplanation)
    } else if let figures, figures.total.hasReportedTokens {
      InspectorLine(
        label: Self.tokensTitle, value: "≈ " + UsagePresentation.tokenSummary(figures.total.tokens),
        help: UsagePresentation.tokensExplanation)
      ForEach(figures.models) { row in
        if case .model(let providerID, let model) = row.key {
          HStack(alignment: .firstTextBaseline) {
            Text(
              verbatim:
                "\(agentNames[providerID] ?? providerID) · \(model ?? String(localized: "Default", bundle: .module, comment: "The model an agent uses when none is chosen."))"
            )
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer()
            Text(UsagePresentation.tokenSummary(row.tokens))
              .monospacedDigit()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 12)
        }
      }
      InspectorLine(
        label: LocalizedStringResource(
          "Responses", bundle: .module,
          comment: "A session's usage: how many answers the agent wrote."),
        value: "\(figures.total.responses)")
      if let missing = figures.transcriptMissingSince {
        Text(
          "A transcript is no longer found; what it reported until \(missing.formatted(date: .abbreviated, time: .shortened)) is kept.",
          bundle: .module, comment: "A date and time."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A label and its value, with an explanation on hover and for VoiceOver.
private struct InspectorLine: View {
  let label: LocalizedStringResource
  let value: String
  var help: String?

  var body: some View {
    LabeledContent {
      Text(value)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .textSelection(.enabled)
    } label: {
      Text(label)
    }
    .font(.callout)
    .help(help ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityHint(help ?? "")
  }
}
