import SwiftUI
import VibeApplication
import VibeDomain

/// The usage of the selected session: the content of the inspector's Usage section (#66).
///
/// What the application measured — running time, runs — is shown as is. What the CLI reported —
/// tokens — carries `≈` and its source. What nobody knows says why, and is never a zero.
struct SessionUsageSection: View {
  let session: WorkSession
  let usage: UsageModel
  let agentNames: [String: String]

  var body: some View {
    SessionUsageFigures(
      figures: usage.sessionUsage[session.id],
      isTrackingEnabled: usage.isTrackingEnabled,
      runsRecordedSince: usage.runsRecordedSince.flatMap { $0 > session.createdAt ? $0 : nil },
      tokenUnavailability: usage.tokenUnavailability(for: session),
      agentNames: agentNames)
  }
}

/// What `SessionUsageSection` shows, from the figures alone.
///
/// Every line keeps its label whole, and every value ends on the right edge, from the narrowest
/// context column up (#130): a value too long beside its label is said a part per line, then
/// goes under its label.
struct SessionUsageFigures: View {
  let figures: SessionUsage?
  let isTrackingEnabled: Bool
  /// When runs started to be recorded, if after the session was created.
  let runsRecordedSince: Date?
  /// Why the session shows no tokens, when it has figures but no reported token.
  let tokenUnavailability: UsageUnavailability?
  let agentNames: [String: String]

  /// The labels follow it in `Text`; the values are said in the same language.
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !isTrackingEnabled {
        InspectorLine(
          label: Text(Self.usageTitle),
          value: UsagePresentation.unavailable(.trackingOff, locale: locale))
      }
      InspectorLine(
        label: Text(
          LocalizedStringResource(
            "Running time", bundle: .module, comment: "A session's usage: how long its agent ran.")
        ),
        value: figures.map { UsagePresentation.duration($0.total.runningTime) } ?? "—",
        help: UsagePresentation.runningTimeExplanation)
      InspectorLine(
        label: Text(
          LocalizedStringResource(
            "Runs", bundle: .module,
            comment: "A session's usage: how many times its agent was started.")),
        value: figures.map { UsagePresentation.runs($0.total.runs, locale: locale) } ?? "—",
        parts: figures.map { UsagePresentation.runParts($0.total.runs, locale: locale) })
      if let since = runsRecordedSince {
        Text(
          "Recorded since \(since.formatted(date: .abbreviated, time: .omitted)).",
          bundle: .module, comment: "The day runs started to be recorded."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      tokens(figures)
      InspectorLine(
        label: Text(
          LocalizedStringResource(
            "Cost", bundle: .module, comment: "A session's usage: what it cost.")),
        value: String(
          localized: LocalizedStringResource(
            "Not available", locale: locale, bundle: .module,
            comment: "A session's cost is unknown.")),
        help: UsagePresentation.costExplanation)
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
    if figures == nil {
      InspectorLine(
        label: Text(Self.tokensTitle), value: "—", help: UsagePresentation.tokensExplanation)
    } else if let reason = tokenUnavailability {
      InspectorLine(
        label: Text(Self.tokensTitle),
        value: UsagePresentation.unavailable(reason, locale: locale),
        help: UsagePresentation.tokensExplanation)
    } else if let figures, figures.total.hasReportedTokens {
      let parts = UsagePresentation.tokenParts(figures.total.tokens, locale: locale)
      InspectorLine(
        label: Text(Self.tokensTitle),
        value: "≈ " + parts.joined(separator: " · "),
        parts: parts.enumerated().map { $0.offset == 0 ? "≈ " + $0.element : $0.element },
        help: UsagePresentation.tokensExplanation)
      ForEach(figures.models) { row in
        if case .model(let providerID, let model) = row.key {
          // The model's name is never cut: two models of an agent differ only at its end.
          InspectorLine(
            label: Text(
              verbatim: "\(agentNames[providerID] ?? providerID) · \(model ?? defaultModel)"),
            value: UsagePresentation.tokenSummary(row.tokens, locale: locale),
            parts: UsagePresentation.tokenParts(row.tokens, locale: locale),
            partPerLine: false,
            font: .caption
          )
          .foregroundStyle(.secondary)
          .padding(.leading, 12)
        }
      }
      InspectorLine(
        label: Text(
          LocalizedStringResource(
            "Responses", bundle: .module,
            comment: "A session's usage: how many answers the agent wrote.")),
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

  private var defaultModel: String {
    String(
      localized: LocalizedStringResource(
        "Default", locale: locale, bundle: .module,
        comment: "The model an agent uses when none is chosen."))
  }
}

/// A label and its value, with an explanation on hover and for VoiceOver.
///
/// The value goes beside its label when both fit on one line; else, when it has parts, a part per
/// line beside its label; else under its label. It ends on the right edge in every case, so the
/// values of a section stay aligned whichever way each line is laid out.
private struct InspectorLine: View {
  let label: Text
  let value: String
  /// The value in parts, each short enough for a line of its own: runs, tokens.
  var parts: [String]?
  /// Whether a part goes on a line of its own when the value does not fit beside its label.
  /// Otherwise, the parts follow each other and the value wraps between them, never inside one.
  var partPerLine = true
  var help: String?
  var font: Font = .callout

  var body: some View {
    ViewThatFits(in: .horizontal) {
      beside(value)
      if let parts, partPerLine, parts.count > 1 {
        beside(parts.joined(separator: "\n"))
      }
      under(underValue)
    }
    .font(font)
    .help(help ?? "")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(value)
    .accessibilityHint(help ?? "")
  }

  private var underValue: String {
    guard let parts else { return value }
    if partPerLine { return parts.joined(separator: "\n") }
    return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
      .joined(separator: " · ")
  }

  private func beside(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      label
      Spacer(minLength: 0)
      valueText(text)
    }
  }

  private func under(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      label
        .fixedSize(horizontal: false, vertical: true)
      valueText(text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func valueText(_ text: String) -> some View {
    Text(text)
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .textSelection(.enabled)
  }
}
