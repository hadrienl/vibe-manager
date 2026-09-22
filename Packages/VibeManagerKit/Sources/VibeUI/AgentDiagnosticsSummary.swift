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
            // Kept on one line and truncated in the middle: the full path belongs to the
            // copied diagnostic, not to the window.
            Text(AgentDiagnostic.redact(path: path))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: 280, alignment: .leading)
              .help(AgentDiagnostic.redact(path: path))
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
    // Leaves room for the build version label in the opposite corner.
    .frame(maxWidth: 520, alignment: .leading)
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
    case .probeFailed(let reason):
      return reason.isTransient ? "clock.badge.exclamationmark" : "exclamationmark.triangle"
    }
  }

  private func tint(for state: AgentAvailabilityState) -> Color {
    switch state {
    case .available: return .green
    case .unauthenticated, .outdated: return .orange
    // Every probe failure is worth an eye, whatever its reason: tinting the silent agent and
    // leaving the broken one grey would rank a transient problem above a real one. The symbol
    // tells them apart, the colour only says that something happened.
    case .probeFailed: return .orange
    // Nothing to be alarmed about: there is simply nothing installed here yet.
    case .notFound, .notExecutable: return .secondary
    }
  }
}
