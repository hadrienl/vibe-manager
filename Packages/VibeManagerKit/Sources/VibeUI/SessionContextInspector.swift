import SwiftUI
import VibeApplication
import VibeDomain

/// The right column: what this session works on, and with what.
///
/// Everything here is read from what the session already carries — its folder, its agent, its
/// notes — except the Git report, which is read from the agent's transcript and the repositories
/// it names, and says how old it is rather than invent a freshness it does not have.
public struct SessionContextInspector: View {
  private let session: WorkSession
  private let resolution: SessionAgentResolution?
  private let branchReport: SessionBranchReport?
  private let refreshBranches: (() -> Void)?

  public init(
    session: WorkSession,
    resolution: SessionAgentResolution?,
    branchReport: SessionBranchReport? = nil,
    refreshBranches: (() -> Void)? = nil
  ) {
    self.session = session
    self.resolution = resolution
    self.branchReport = branchReport
    self.refreshBranches = refreshBranches
  }

  public var body: some View {
    List {
      // The folder the session was opened on, then each branch the agent worked on as a heading,
      // with the repositories it is checked out in under it. The branches and worktrees are the
      // agent's own: the application only reports them.
      Section {
        if session.repositories.isEmpty {
          InspectorPlaceholder("No folder is attached to this session.")
        } else {
          ForEach(session.repositories) { repository in
            RepositoryRow(repository: repository)
          }
        }
        branchContent
      } header: {
        HStack(spacing: 6) {
          Text("Git")
          Spacer()
          if let branchReport {
            // The age is said, never implied: this is what was read, not a live view.
            TimelineView(.periodic(from: .now, by: 10)) { context in
              Text(age(of: branchReport.readAt, at: context.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
          if let refreshBranches {
            Button(action: refreshBranches) { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.borderless)
              .help("Read the repositories again")
              .accessibilityLabel("Read the repositories again")
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

extension SessionContextInspector {
  @ViewBuilder
  fileprivate var branchContent: some View {
    if let branchReport {
      let groups = BranchGroup.groups(of: branchReport.repositories)
      if groups.isEmpty {
        Text(
          branchReport.hasTranscript
            ? "No repository worked in yet."
            : "No transcript of this session was found, so only what is attached can be shown."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(groups) { group in
        BranchGroupView(group: group)
      }
      if !branchReport.visitedOnly.isEmpty {
        Text("Also looked in: \(branchReport.visitedOnly.joined(separator: ", "))")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else if refreshBranches != nil, !session.repositories.isEmpty {
      Text("Reading the repositories…")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

private func age(of date: Date, at now: Date) -> String {
  let seconds = max(0, Int(now.timeIntervalSince(date)))
  if seconds < 10 { return "read just now" }
  if seconds < 60 { return "read \(seconds / 10 * 10) s ago" }
  return "read at \(date.formatted(date: .omitted, time: .shortened))"
}

/// One branch the session worked on, and the repositories it is checked out in.
private struct BranchGroup: Identifiable {
  struct Entry: Identifiable {
    let report: RepositoryBranchReport
    /// The repository, without the worktree it was reached through.
    let repository: String
    /// "worktree oauth-token-store" for a worktree an agent made for itself.
    let location: String?

    var id: String { report.id }
  }

  let branch: String?
  let entries: [Entry]

  var id: String { branch ?? "detached" }

  /// Created during the session, in at least one of its repositories.
  var isNew: Bool { entries.contains { $0.report.change?.kind == .created } }

  /// In the order the repositories come: attached ones first, then those the agent went into.
  static func groups(of reports: [RepositoryBranchReport]) -> [BranchGroup] {
    var order: [String?] = []
    var entries: [String?: [Entry]] = [:]
    for report in reports {
      let branch = report.isUnreadable ? nil : report.checkedOutBranch
      if entries[branch] == nil { order.append(branch) }
      let parts = report.name.components(separatedBy: " · worktree ")
      entries[branch, default: []].append(
        Entry(
          report: report,
          repository: parts[0],
          location: parts.count > 1 ? "worktree \(parts[1])" : nil
        ))
    }
    return order.map { BranchGroup(branch: $0, entries: entries[$0] ?? []) }
  }
}

private struct BranchGroupView: View {
  let group: BranchGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption)
          .foregroundStyle(.secondary)
        // Whole, on as many lines as it takes: a branch cut in its middle is a branch nobody
        // can recognise.
        Text(group.branch ?? "No branch")
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(group.branch == nil ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if group.isNew {
          Pill("new", color: .green)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        ForEach(group.entries) { entry in
          EntryRow(entry: entry)
        }
      }
      .padding(.leading, 18)
    }
    .padding(.vertical, 3)
  }
}

private struct EntryRow: View {
  let entry: BranchGroup.Entry

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(entry.repository)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .help(entry.report.path)
        ForEach(pills, id: \.label) { pill in
          Pill(pill.label, color: pill.color)
        }
      }
      if let location = entry.location {
        Text(location)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var pills: [(label: String, color: Color)] {
    let report = entry.report
    var pills: [(String, Color)] = []
    if report.isUnreadable { return [("unreadable", .secondary)] }
    if let change = report.change {
      switch change.kind {
      case .created, .advanced:
        if let count = change.commitCount, count > 0 { pills.append(("+\(count)", .blue)) }
      case .rewritten:
        pills.append(("rewritten", .orange))
      }
    }
    if report.isDirty { pills.append(("modified", .orange)) }
    return pills
  }
}

private struct Pill: View {
  let label: String
  let color: Color

  init(_ label: String, color: Color) {
    self.label = label
    self.color = color
  }

  var body: some View {
    Text(label)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .foregroundStyle(color)
      .background(Capsule().fill(color.opacity(0.18)))
      .fixedSize()
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
