import SwiftUI
import VibeApplication

/// Minimal surface for #3: shows what was detected and lets the user copy a diagnostic.
/// The real provider pickers belong to #7 and #8.
struct AgentDiagnosticsSummary: View {
  let diagnostics: [AgentDiagnostic]
  let isRefreshing: Bool
  let refresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(diagnostics, id: \.providerID) { diagnostic in
        HStack(spacing: 6) {
          Image(systemName: symbolName(for: diagnostic.state))
            .foregroundStyle(tint(for: diagnostic.state))
          Text(diagnostic.summary)
          if let path = diagnostic.installation?.executablePath {
            Text(AgentDiagnostic.redact(path: path))
              .foregroundStyle(.tertiary)
          }
          Button {
            copy(diagnostic)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy diagnostic")
        }
      }

      Button(isRefreshing ? "Checking agents…" : "Check Agents Again", action: refresh)
        .buttonStyle(.link)
        .disabled(isRefreshing)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func copy(_ diagnostic: AgentDiagnostic) {
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(diagnostic.exportText(), forType: .string)
    #endif
  }

  private func symbolName(for state: AgentAvailabilityState) -> String {
    switch state {
    case .available: return "checkmark.circle"
    case .unauthenticated: return "person.crop.circle.badge.questionmark"
    case .outdated: return "arrow.up.circle"
    case .notFound, .notExecutable: return "questionmark.circle"
    case .probeFailed: return "exclamationmark.triangle"
    }
  }

  private func tint(for state: AgentAvailabilityState) -> Color {
    switch state {
    case .available: return .green
    case .unauthenticated, .outdated: return .orange
    case .notFound, .notExecutable, .probeFailed: return .secondary
    }
  }
}
