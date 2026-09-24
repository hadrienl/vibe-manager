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
        InspectorLine(label: "Usage", value: UsagePresentation.unavailable(.trackingOff))
      }
      let figures = usage.sessionUsage[session.id]
      InspectorLine(
        label: "Running time",
        value: figures.map { UsagePresentation.duration($0.total.runningTime) } ?? "—",
        help: UsagePresentation.runningTimeExplanation)
      InspectorLine(
        label: "Runs", value: figures.map { UsagePresentation.runs($0.total.runs) } ?? "—")
      if let since = usage.runsRecordedSince, since > session.createdAt {
        Text("Recorded since \(since.formatted(date: .abbreviated, time: .omitted)).")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      tokens(figures)
      InspectorLine(label: "Cost", value: "Not available", help: UsagePresentation.costExplanation)
    } header: {
      HStack {
        Text("Usage")
        Spacer()
        if usage.isReading {
          ProgressView().controlSize(.mini)
            .accessibilityLabel("Reading transcripts")
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

  @ViewBuilder
  private func tokens(_ figures: SessionUsage?) -> some View {
    if usage.sessionUsage[session.id] == nil {
      InspectorLine(label: "Tokens", value: "—", help: UsagePresentation.tokensExplanation)
    } else if let reason = usage.tokenUnavailability(for: session) {
      InspectorLine(
        label: "Tokens", value: UsagePresentation.unavailable(reason),
        help: UsagePresentation.tokensExplanation)
    } else if let figures, figures.total.hasReportedTokens {
      InspectorLine(
        label: "Tokens", value: "≈ " + UsagePresentation.tokenSummary(figures.total.tokens),
        help: UsagePresentation.tokensExplanation)
      ForEach(figures.models) { row in
        if case .model(let providerID, let model) = row.key {
          HStack(alignment: .firstTextBaseline) {
            Text("\(agentNames[providerID] ?? providerID) · \(model ?? "Default")")
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
      InspectorLine(label: "Responses", value: "\(figures.total.responses)")
      if let missing = figures.transcriptMissingSince {
        Text(
          "A transcript is no longer found; what it reported until \(missing.formatted(date: .abbreviated, time: .shortened)) is kept."
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
  let label: String
  let value: String
  var help: String?

  var body: some View {
    LabeledContent(label) {
      Text(value)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .textSelection(.enabled)
    }
    .font(.callout)
    .help(help ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityHint(help ?? "")
  }
}
