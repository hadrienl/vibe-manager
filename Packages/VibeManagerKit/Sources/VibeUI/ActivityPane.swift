import SwiftUI
import VibeApplication
import VibeDomain

/// What the session did (#36): the summary its agent writes, then the tickets, requests, branches
/// and worktrees it used, each opening what it names.
///
/// One list, so that the arrows go from the summary to the resources and back, Return opens and
/// ⌘C copies whatever is selected.
struct ActivityPane: View {
  let session: WorkSession
  let agentName: String
  @Bindable var journal: SessionJournalModel
  @Environment(\.openSettings) private var openSettings
  @FocusState private var isListFocused: Bool

  var body: some View {
    let current = journal.journal(for: session.id)
    let resources = current?.resources ?? []
    List(selection: selection) {
      Section {
        if let notice = journal.notice {
          Label(notice, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        entries(current, resources: resources)
        status(current)
      } header: {
        Text("Summary", bundle: .module, comment: "The heading of a session's summary.")
      }
      resourceSections(current)
    }
    .listStyle(.sidebar)
    .focused($isListFocused)
    .onChange(of: journal.focusRequest) { takeFocus() }
    // A turn later: a list that has just appeared does not take the keyboard yet.
    .onAppear { if journal.isFocusPending { Task { @MainActor in takeFocus() } } }
    .accessibilityIdentifier("inspector-activity")
    .contextMenu(forSelectionType: ActivityRowID.self) { ids in
      if let id = ids.first { menu(for: id, current: current) }
    } primaryAction: { ids in
      guard let id = ids.first else { return }
      journal.activate(id, in: session.id)
    }
    .onCopyCommand {
      guard let selected = journal.selection(in: session.id) else { return [] }
      journal.copy(selected, in: session.id)
      return []
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        journal.openLink(url, from: session.id)
        return .handled
      }
    )
    .task(id: session.id) { journal.load(session.id) }
  }

  private func takeFocus() {
    isListFocused = true
    journal.focusTaken()
  }

  private var selection: Binding<ActivityRowID?> {
    Binding(
      get: { journal.selection(in: session.id) },
      set: { journal.select($0, in: session.id) }
    )
  }

  // MARK: - Summary

  @ViewBuilder
  private func entries(_ current: SessionJournal?, resources: [SessionResource]) -> some View {
    let all = current?.entries ?? []
    let (rows, hidden) = ActivityPresentation.entryRows(
      all, limit: journal.shownEntryCount(in: session.id))
    if hidden > 0 {
      Button {
        journal.showEarlier(in: session.id)
      } label: {
        Text(
          "Show \(min(hidden, SessionJournalModel.pageSize)) Earlier", bundle: .module,
          comment: "Shows older entries of the summary; a count.")
      }
      .buttonStyle(.link)
      .font(.caption)
    }
    ForEach(rows) { row in
      switch row {
      case .day(let date):
        Text(date.formatted(date: .abbreviated, time: .omitted))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      case .entry(let entry):
        EntryRow(entry: entry, resources: resources) { journal.openLink($0, from: session.id) }
          .tag(ActivityRowID.entry(entry.id))
      }
    }
  }

  @ViewBuilder
  private func status(_ current: SessionJournal?) -> some View {
    let status = ActivityPresentation.summaryStatus(
      journal: current, session: session, summariesEnabled: journal.summariesEnabled)
    if journal.isSummarizing(session.id) {
      SummarizingIndicator()
    }
    if let sentence = ActivityPresentation.sentence(for: status, agentName: agentName) {
      VStack(alignment: .leading, spacing: 4) {
        Text(sentence)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        switch status {
        case .failed, .unavailable:
          Button {
            journal.retry(session.id)
          } label: {
            Text("Retry", bundle: .module, comment: "Tries the summary again.")
          }
          .controlSize(.small)
        case .disabled:
          Button {
            journal.showSettingsTab?()
            openSettings()
          } label: {
            Text("Open Settings…", bundle: .module)
          }
          .buttonStyle(.link)
          .font(.caption)
        default:
          EmptyView()
        }
      }
    }
  }

  // MARK: - Resources

  @ViewBuilder
  private func resourceSections(_ current: SessionJournal?) -> some View {
    let resources = current?.resources ?? []
    if resources.isEmpty {
      Section {
        Text("No ticket, request, branch or worktree yet.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Resources", bundle: .module, comment: "The heading of the resources a session used.")
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    ForEach(ActivityPresentation.groups, id: \.self) { kind in
      let group = resources.filter { $0.kind == kind }
      if !group.isEmpty {
        Section {
          ForEach(group) { resource in
            ResourceRow(resource: resource)
              .tag(ActivityRowID.resource(resource.key))
          }
        } header: {
          Text(ActivityPresentation.groupTitle(kind))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    if let overflow = current?.overflowResourceCount, overflow > 0 {
      Text(
        "\(overflow) more resources were not kept.", bundle: .module,
        comment: "Resources past the journal's bound; a count."
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func menu(for id: ActivityRowID, current: SessionJournal?) -> some View {
    switch id {
    case .entry(let entryID):
      if let entry = current?.entries.first(where: { $0.id == entryID }) {
        Button {
          journal.copy(ActivityPresentation.entryText(entry))
        } label: {
          Text("Copy", bundle: .module)
        }
        // Each link its own menu, with the actions of every link (#186).
        ForEach(ActivityPresentation.links(in: entry.text), id: \.self) { url in
          Menu(url.absoluteString) {
            LinkActions(url: url, session: session.id, journal: journal, includesCopy: true)
          }
        }
      }
    case .resource(let key):
      if let resource = current?.resources.first(where: { $0.key == key }) {
        ResourceMenu(resource: resource, session: session.id, journal: journal)
      }
    }
  }
}

/// A line of the summary: its time, its text with its links.
private struct EntryRow: View {
  let entry: JournalEntry
  let resources: [SessionResource]
  let open: (URL) -> Void

  var body: some View {
    let links = ActivityPresentation.links(in: entry.text)
    let time = entry.at.formatted(date: .omitted, time: .shortened)
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(verbatim: time)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
      Text(ActivityPresentation.attributedText(entry, resources: resources))
        .font(.callout)
        .foregroundStyle(entry.foldedCount == nil ? .primary : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .help(links.map(\.absoluteString).joined(separator: "\n"))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: "\(time), \(ActivityPresentation.entryText(entry))"))
    .accessibilityActions {
      ForEach(links, id: \.self) { url in
        Button {
          open(url)
        } label: {
          Text(
            "Open \(ActivityPresentation.shortName(of: url, resources: resources) ?? url.absoluteString)",
            bundle: .module, comment: "Opens a link of the summary; the URL or its short name.")
        }
      }
    }
  }
}

/// A resource: its kind, its short name, where it belongs, and what the session did with it — in
/// words, never by a colour alone. Every word of it is shown, on as many lines as it takes (#279).
struct ResourceRow: View {
  let resource: SessionResource

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: ActivityPresentation.symbol(resource.kind))
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: ActivityPresentation.breakable(resource.label))
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: ActivityPresentation.breakable(ActivityPresentation.caption(resource)))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .help(ActivityPresentation.help(resource))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: ActivityPresentation.spokenLabel(resource)))
    .accessibilityAddTraits(.isButton)
  }
}

/// The actions of a link, as every link's menu has them (#186). Copy Link is left out where the
/// menu has its own Copy URL.
private struct LinkActions: View {
  let url: URL
  let session: SessionID
  let journal: SessionJournalModel
  let includesCopy: Bool

  var body: some View {
    let actions = journal.linkActions(for: url, in: session).filter { includesCopy || $0 != .copy }
    ForEach(actions, id: \.title) { action in
      Button(action.title) { journal.perform(action, on: url, from: session) }
    }
  }
}

private struct ResourceMenu: View {
  let resource: SessionResource
  let session: SessionID
  let journal: SessionJournalModel

  var body: some View {
    switch resource.target {
    case .web(let url):
      LinkActions(url: url, session: session, journal: journal, includesCopy: false)
      Button {
        journal.copy(url.absoluteString)
      } label: {
        Text("Copy URL", bundle: .module)
      }
      Button {
        journal.copy(ActivityPresentation.reference(resource))
      } label: {
        Text("Copy Reference", bundle: .module, comment: "Copies “owner/repo#36”.")
      }
    case .branch(let path, let url):
      if let url {
        LinkActions(url: url, session: session, journal: journal, includesCopy: false)
      }
      Button {
        journal.copy(resource.label)
      } label: {
        Text("Copy Name", bundle: .module, comment: "Copies a branch's name.")
      }
      Button {
        journal.revealFolder(path)
      } label: {
        Text("Reveal Repository in Finder", bundle: .module)
      }
    case .folder(let path):
      Button {
        journal.revealFolder(path)
      } label: {
        Text("Reveal in Finder", bundle: .module)
      }
      if let editor = journal.editorName {
        Button {
          journal.openInEditor(path)
        } label: {
          Text("Open in \(editor)", bundle: .module, comment: "An editor's name.")
        }
      }
      Button {
        journal.copy(path)
      } label: {
        Text("Copy Path", bundle: .module)
      }
    }
  }
}

/// "Summarizing…", said only once a pass has lasted long enough to be worth saying.
private struct SummarizingIndicator: View {
  @State private var isShown = false

  var body: some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small)
      Text("Summarizing…", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .opacity(isShown ? 1 : 0)
    .task {
      try? await Task.sleep(for: .milliseconds(300))
      isShown = true
    }
  }
}
