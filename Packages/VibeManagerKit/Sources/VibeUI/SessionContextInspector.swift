import SwiftUI
import VibeApplication
import VibeDomain

/// The right column: what this session works on, and with what.
///
/// Everything here is read from what the session already carries — its repositories and the Git
/// snapshot captured when it was stored, its agent, its notes. Nothing is queried: a live Git
/// status and editable notes are their own tickets, and this column has to be honest about the
/// age of what it shows rather than invent a freshness it does not have.
public struct SessionContextInspector: View {
  private let session: WorkSession
  private let resolution: SessionAgentResolution?

  public init(session: WorkSession, resolution: SessionAgentResolution?) {
    self.session = session
    self.resolution = resolution
  }

  public var body: some View {
    List {
      Section("Repositories") {
        if session.repositories.isEmpty {
          InspectorPlaceholder("No folder is attached to this session.")
        } else {
          ForEach(session.repositories) { repository in
            RepositoryRow(repository: repository)
          }
        }
      }

      Section("Agent") {
        AgentRow(agent: session.agent, resolution: resolution)
      }

      Section("Notes") {
        if let notes = session.notes, !notes.isEmpty {
          Text(notes)
            .font(.callout)
            .textSelection(.enabled)
        } else {
          InspectorPlaceholder("No notes yet.")
        }
      }

      Section("Initial prompt") {
        if session.initialPrompt.isEmpty {
          InspectorPlaceholder("This session was started without a prompt.")
        } else {
          // Folded by default: a prompt can be long, and the context of the session is what the
          // column is for. Unfolding it is one click, scrolling past it every time is not.
          DisclosureGroup("Show prompt") {
            Text(session.initialPrompt)
              .font(.callout)
              .textSelection(.enabled)
              .padding(.top, 4)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

private struct RepositoryRow: View {
  let repository: RepositoryContext

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(name, systemImage: "folder")
        .lineLimit(1)
      Text(repository.path)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
        .help(repository.path)

      if let git = repository.git {
        HStack(spacing: 6) {
          Label(git.branchName ?? "detached", systemImage: "arrow.triangle.branch")
          // Written out, never a coloured dot on its own.
          Text(git.isDirty ? "Modified" : "Clean")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Text("Captured \(git.capturedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      } else {
        Text("No Git snapshot yet.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private var name: String {
    let component = URL(fileURLWithPath: repository.path).lastPathComponent
    return component.isEmpty ? repository.path : component
  }
}

private struct AgentRow: View {
  let agent: SessionAgentConfiguration?
  let resolution: SessionAgentResolution?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let agent {
        Label(
          agent.modelID.map { "\(agent.providerID) · \($0)" } ?? agent.providerID,
          systemImage: "cpu"
        )
        .lineLimit(1)
      } else {
        Label("No agent recorded", systemImage: "cpu")
          .lineLimit(1)
      }

      Text(statusSentence)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private var statusSentence: String {
    switch resolution {
    case .ready:
      return "Ready to resume."
    case .unavailable(let diagnostic):
      return diagnostic.summary
    case .unknownProvider(let providerID):
      return "The provider \(providerID) is not installed in this build."
    case .unassigned:
      return "This session was stored without an agent."
    case .none:
      return "Detection has not answered yet."
    }
  }
}

private struct InspectorPlaceholder: View {
  private let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
  }
}
