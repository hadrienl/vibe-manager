import SwiftUI
import VibeApplication
import VibeDomain

/// The coordination section of the context column (#352): a coordinator's children, one row each
/// — state, task status, ticket, pull request, time since it started — or, for a child, its
/// coordinator and what the coordinator did there.
struct CoordinationPane: View {
  let model: AppModel
  let session: WorkSession

  var body: some View {
    List {
      if session.coordination?.isCoordinator == true {
        let children = model.children(of: session.id)
        if children.isEmpty {
          Text(
            "No child session yet. The coordinator creates them as it works.", bundle: .module,
            comment: "The Children section of a coordinator that has none."
          )
          .foregroundStyle(.secondary)
        }
        ForEach(children) { child in
          CoordinationChildRow(model: model, child: child)
        }
      } else if let parentID = session.coordination?.coordinatorID {
        if let parent = model.sessions.first(where: { $0.id == parentID }) {
          Button {
            model.goToSession(parent.id)
          } label: {
            Label {
              Text(
                "Coordinated by “\(parent.name)”", bundle: .module,
                comment: "In a child session's inspector: its coordinator's name.")
            } icon: {
              Image(systemName: "person.2")
            }
          }
          .buttonStyle(.link)
        }
        let trace = model.coordinationTrace(of: session.id)
        if !trace.isEmpty {
          Section {
            ForEach(Array(trace.enumerated().reversed()), id: \.offset) { _, entry in
              CoordinationTraceRow(entry: entry)
            }
          } header: {
            Text(
              "What the coordinator did", bundle: .module,
              comment: "In a child session's inspector: the list of its coordinator's actions.")
          }
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .task(id: session.id) {
      await model.loadCoordinationTrace(of: session.id)
    }
  }
}

/// A child in its coordinator's section: a click opens it.
private struct CoordinationChildRow: View {
  let model: AppModel
  let child: WorkSession

  var body: some View {
    let status = model.statusPresentation(for: child)
    Button {
      model.goToSession(child.id)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: status.symbolName)
          .foregroundStyle(status.needsAttention ? Color.orange : .secondary)
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          Text(child.name).lineLimit(1)
          HStack(spacing: 4) {
            Text(status.label)
            Text(verbatim: "·")
            Text(child.taskStatus.label)
            if let started = child.startedAt {
              Text(verbatim: "·")
              Text(started, style: .relative)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          if let ticket = child.ticket?.url {
            Text(verbatim: ticket.absoluteString)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint(Text("Opens the session", bundle: .module))
  }
}

/// One thing the coordinator did to a child, newest first.
private struct CoordinationTraceRow: View {
  let entry: CoordinationTraceEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text(entry.date, style: .time)
          .foregroundStyle(.secondary)
        action
      }
      .font(.caption)
      if let detail = entry.detail {
        Text(verbatim: DisplaySafeText.visible(detail))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var action: Text {
    switch entry.action {
    case .created:
      return Text(
        "Created by “\(entry.coordinatorName)”", bundle: .module,
        comment: "A coordinator's action on a child session.")
    case .messaged:
      return Text(
        "Message from “\(entry.coordinatorName)”", bundle: .module,
        comment: "A coordinator's action on a child session.")
    case .movedTo(let status):
      return Text(
        "Moved to \(String(localized: status.label)) by “\(entry.coordinatorName)”",
        bundle: .module,
        comment:
          "A coordinator's action on a child session: a task status, then the coordinator's name.")
    case .started:
      return Text(
        "Started by “\(entry.coordinatorName)”", bundle: .module,
        comment: "A coordinator's action on a child session.")
    case .closed:
      return Text(
        "Stopped by “\(entry.coordinatorName)”", bundle: .module,
        comment: "A coordinator's action on a child session.")
    }
  }
}

/// What the coordination section says once folded.
struct CoordinationSummaryText: View {
  let model: AppModel
  let session: WorkSession

  var body: some View {
    if session.coordination?.isCoordinator == true {
      let summary = model.summary(ofCoordinator: session.id)
      if summary.needingUser > 0 {
        Text(
          "\(summary.needingUser) need you", bundle: .module,
          comment: "How many child sessions of a coordinator wait for the user.")
      } else {
        Text(
          "\(summary.count) children", bundle: .module,
          comment: "How many child sessions a coordinator has.")
      }
    } else if let parentID = session.coordination?.coordinatorID,
      let parent = model.sessions.first(where: { $0.id == parentID })
    {
      Text(verbatim: parent.name)
    }
  }
}
