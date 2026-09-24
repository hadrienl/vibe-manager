import SwiftUI
import VibeDomain

/// What each pattern applied to a field keeps of a value: `/\d+$/ → 1315`, one line per pattern.
///
/// The same lines under the tester of the template editor and under the field of the New Session
/// sheet, so what was tried is what will be extracted.
struct ExtractionResultsView: View {
  let results: [(use: PromptTemplateExtractionUse, outcome: PromptTemplateExtraction.Outcome)]
  /// Says where each pattern is used — worth it where the template is written, not where it is
  /// filled in.
  var showsPlaces = false

  var body: some View {
    if !results.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(results, id: \.use.id) { result in
          row(result.use, result.outcome)
        }
      }
      .font(.caption)
    }
  }

  private func row(
    _ use: PromptTemplateExtractionUse, _ outcome: PromptTemplateExtraction.Outcome
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "arrow.turn.down.right")
        .foregroundStyle(.tertiary)
      Text("/\(use.pattern)/")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("The first match, or its first group when there is one.")
      Text("→")
        .foregroundStyle(.tertiary)
      outcomeLabel(outcome)
      Spacer(minLength: 8)
      if showsPlaces {
        Text(use.placesLabel)
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func outcomeLabel(_ outcome: PromptTemplateExtraction.Outcome) -> some View {
    switch outcome {
    case .extracted(let part) where part.isEmpty:
      Text("nothing yet")
        .foregroundStyle(.tertiary)
    case .extracted(let part):
      Text(part)
        .fontWeight(.semibold)
        .textSelection(.enabled)
        .lineLimit(1)
    case .noMatch:
      Label("no match", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    case .invalid(let reason):
      Label("Invalid pattern: \(reason)", systemImage: "xmark.octagon")
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }
}
