import SwiftUI
import VibeApplication
import VibeDomain

/// The right column: what this session works on, and with what (#66).
///
/// A stack of sections — the activity, Git, the notes, the agent, its usage, the prompt it started
/// from — that the user folds, orders and sizes; `InspectorSectionStack` does all of that. This
/// view only declares them: adding one is adding a descriptor, never touching the layout.
///
/// Everything in the Git section is what Git and the agent's transcript say, in Git's order: the
/// application reveals and opens files, and never acts on Git.
struct SessionContextInspector: View {
  private let session: WorkSession
  private let resolution: SessionAgentResolution?
  private let branchReport: SessionBranchReport?
  private let branchReportCheckedAt: (() -> Date?)?
  private let repositoryStatuses: [String: RepositoryStatusState]
  private let sessionNames: [SessionID: String]
  private let refreshBranches: (() -> Void)?
  private let git: GitInspectorModel
  private let layout: WorkspaceLayoutController
  private let openPrivacySettings: (() -> Void)?
  private let agentNames: [String: String]
  private let switchAgent: (() -> Void)?
  private let notes: NotesModel?
  private let ticketTitles: TicketTitlesModel?
  private let leaveNotes: () -> Void
  private let usage: UsageModel?
  private let journal: SessionJournalModel?

  init(
    session: WorkSession,
    resolution: SessionAgentResolution?,
    branchReport: SessionBranchReport? = nil,
    branchReportCheckedAt: (() -> Date?)? = nil,
    repositoryStatuses: [RepositoryStatusKey: RepositoryStatusState] = [:],
    sessionNames: [SessionID: String] = [:],
    refreshBranches: (() -> Void)? = nil,
    git: GitInspectorModel,
    layout: WorkspaceLayoutController,
    openPrivacySettings: (() -> Void)? = nil,
    agentNames: [String: String] = [:],
    switchAgent: (() -> Void)? = nil,
    notes: NotesModel? = nil,
    ticketTitles: TicketTitlesModel? = nil,
    leaveNotes: @escaping () -> Void = {},
    usage: UsageModel? = nil,
    journal: SessionJournalModel? = nil
  ) {
    self.session = session
    self.journal = journal
    self.notes = notes
    self.ticketTitles = ticketTitles
    self.leaveNotes = leaveNotes
    self.usage = usage
    self.resolution = resolution
    self.branchReport = branchReport
    self.branchReportCheckedAt = branchReportCheckedAt
    var byPath: [String: RepositoryStatusState] = [:]
    for (key, state) in repositoryStatuses where key.sessionID == session.id {
      byPath[key.repositoryPath] = state
    }
    self.repositoryStatuses = byPath
    self.sessionNames = sessionNames
    self.refreshBranches = refreshBranches
    self.git = git
    self.layout = layout
    self.openPrivacySettings = openPrivacySettings
    self.agentNames = agentNames
    self.switchAgent = switchAgent
  }

  var body: some View {
    InspectorSectionStack(sections: sections, layout: layout)
  }

  /// In their default order. A section with nothing to show in this window — no journal, no
  /// usage — is left out, and keeps its place in the arrangement for when it comes back.
  private var sections: [InspectorSectionDescriptor] {
    var sections: [InspectorSectionDescriptor] = []
    if let journal {
      sections.append(activitySection(journal))
    }
    sections.append(gitSection)
    if let notes {
      sections.append(notesSection(notes))
    }
    sections.append(agentSection)
    if let usage {
      sections.append(usageSection(usage))
    }
    sections.append(promptSection)
    return sections
  }
}

// MARK: - The sections

extension SessionContextInspector {
  fileprivate func activitySection(_ journal: SessionJournalModel) -> InspectorSectionDescriptor {
    InspectorSectionDescriptor(
      id: .activity,
      title: String(localized: "Activity", bundle: .module, comment: "A section of the inspector."),
      systemImage: "waveform.path.ecg",
      sizing: .fill(minimum: 90),
      summary: AnyView(ActivitySummary(session: session.id, journal: journal)),
      summaryText: activitySummaryText(journal),
      content: AnyView(
        ActivityPane(
          session: session,
          agentName: session.agent.flatMap { agentNames[$0.providerID] }
            ?? session.agent?.providerID ?? "",
          journal: journal)),
      accessibilityIdentifier: "inspector-activity-section"
    )
  }

  fileprivate func activitySummaryText(_ journal: SessionJournalModel) -> String? {
    let count = journal.journal(for: session.id)?.resources.count ?? 0
    return count > 0 ? ActivityPresentation.resourceCount(count) : nil
  }

  fileprivate var gitSection: InspectorSectionDescriptor {
    InspectorSectionDescriptor(
      id: .git,
      title: "Git",
      systemImage: "arrow.triangle.branch",
      sizing: .fill(minimum: 120),
      summary: AnyView(
        GitSummary(
          session: session, branchReport: branchReport, statuses: repositoryStatuses,
          sessionNames: sessionNames, git: git)),
      accessory: AnyView(
        GitAccessory(
          branchReport: branchReport, checkedAt: branchReportCheckedAt,
          statuses: repositoryStatuses, refresh: refreshBranches)
      ),
      content: AnyView(
        GitPane(
          session: session,
          branchReport: branchReport,
          statuses: repositoryStatuses,
          sessionNames: sessionNames,
          refresh: refreshBranches,
          openPrivacySettings: openPrivacySettings,
          git: git
        )),
      accessibilityIdentifier: "inspector-git-section"
    )
  }

  fileprivate func notesSection(_ notes: NotesModel) -> InspectorSectionDescriptor {
    let document = notes.document(for: session.id)
    return InspectorSectionDescriptor(
      id: .notes,
      title: String(
        localized: "Notes", bundle: .module, comment: "The heading of a session's notes."),
      systemImage: "note.text",
      sizing: .fill(minimum: 90),
      summary: AnyView(NotesSummary(document: document)),
      accessory: AnyView(NotesStateLabel(document: document)),
      content: AnyView(
        SessionNotesSection(
          session: session, document: document, notes: notes, ticketTitles: ticketTitles,
          leave: leaveNotes)),
      accessibilityIdentifier: "inspector-notes-section"
    )
  }

  fileprivate var agentSection: InspectorSectionDescriptor {
    InspectorSectionDescriptor(
      id: .agent,
      title: String(
        localized: "Agent", bundle: .module, comment: "The heading of the session's agent."),
      systemImage: "cpu",
      sizing: .fitting(minimum: 60),
      summary: AnyView(
        Text(
          session.agent.map { AgentHistoryList.label($0, names: agentNames) }
            ?? String(localized: "No agent recorded", bundle: .module))),
      accessory: switchAgent.map { switchAgent in
        AnyView(
          Button(action: switchAgent) {
            Text("Switch…", bundle: .module, comment: "Opens the sheet that switches the agent.")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityLabel(
            Text(
              "Switch the agent of \(session.name)", bundle: .module,
              comment: "The session's name.")))
      },
      content: AnyView(
        VStack(alignment: .leading, spacing: 8) {
          AgentRow(agent: session.agent, resolution: resolution, names: agentNames)
          if !session.agentHistory.isEmpty {
            AgentHistoryList(session: session, names: agentNames)
          }
        })
    )
  }

  fileprivate func usageSection(_ usage: UsageModel) -> InspectorSectionDescriptor {
    InspectorSectionDescriptor(
      id: .usage,
      title: String(localized: "Usage", bundle: .module, comment: "A session's usage, heading."),
      systemImage: "chart.bar",
      sizing: .fitting(minimum: 60),
      summary: AnyView(UsageSummary(session: session.id, usage: usage)),
      // Always in the header, folded or not: the figures of the summary need watching too.
      accessory: AnyView(UsageWatcher(session: session.id, usage: usage)),
      content: AnyView(SessionUsageSection(session: session, usage: usage, agentNames: agentNames))
    )
  }

  fileprivate var promptSection: InspectorSectionDescriptor {
    InspectorSectionDescriptor(
      id: .prompt,
      title: String(localized: "Initial prompt", bundle: .module),
      systemImage: "text.bubble",
      sizing: .fitting(minimum: 60),
      summary: AnyView(Text(Self.promptSummary(session))),
      content: AnyView(InitialPromptView(session: session))
    )
  }

  static func promptSummary(_ session: WorkSession) -> String {
    if let template = session.template {
      return template.name
    }
    if let line = session.initialPrompt.split(whereSeparator: \.isNewline).first {
      return String(line)
    }
    return String(
      localized: "No prompt", bundle: .module, comment: "A session was started without a prompt.")
  }
}

/// The prompt the session started from, whole: the section folds, the prompt does not.
private struct InitialPromptView: View {
  let session: WorkSession

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // The name and revision the session was created with: the template may since have been
      // renamed, changed or deleted, and none of that changes what this session was sent.
      if let template = session.template {
        Group {
          if let revision = template.revision {
            Text(
              "From template “\(template.name)”, revision \(String(revision))",
              bundle: .module, comment: "A prompt template's name, then its revision number.")
          } else {
            Text(
              "From template “\(template.name)”", bundle: .module,
              comment: "A prompt template's name.")
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      if session.initialPrompt.isEmpty {
        InspectorPlaceholder(
          LocalizedStringResource("This session was started without a prompt.", bundle: .module))
      } else {
        Text(session.initialPrompt)
          .font(.callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// What the activity holds, said once the section is folded.
private struct ActivitySummary: View {
  let session: SessionID
  let journal: SessionJournalModel

  var body: some View {
    let count = journal.journal(for: session)?.resources.count ?? 0
    if count > 0 {
      Text(verbatim: ActivityPresentation.resourceCount(count))
    }
  }
}

/// Repositories and changed files, said once the Git section is folded.
private struct GitSummary: View {
  let session: WorkSession
  let branchReport: SessionBranchReport?
  let statuses: [String: RepositoryStatusState]
  let sessionNames: [SessionID: String]
  let git: GitInspectorModel

  var body: some View {
    if let repositories = branchReport?.repositories, !repositories.isEmpty {
      let changes = repositories.reduce(0) { total, repository in
        total
          + git.group(for: repository, state: statuses[repository.path], sessionNames: sessionNames)
          .changeCount
      }
      let repositoryCount = String(
        localized: "\(repositories.count) repositories", bundle: .module,
        comment: "What the Git section holds once folded: how many repositories.")
      let changeCount = String(
        localized: "\(changes) changes", bundle: .module,
        comment: "What the Git section holds once folded: how many changed files.")
      Text(verbatim: "\(repositoryCount) · \(changeCount)")
    }
  }
}

/// Whether the Git list is live or how old it is, and the button that reads it again.
private struct GitAccessory: View {
  let branchReport: SessionBranchReport?
  /// Read here rather than by the inspector: it moves at every reading, the report does not.
  let checkedAt: (() -> Date?)?
  let statuses: [String: RepositoryStatusState]
  let refresh: (() -> Void)?

  var body: some View {
    HStack(spacing: 6) {
      if isLive {
        // Said only when it is true: every repository is watched and its last reading held.
        Text(
          "live", bundle: .module,
          comment: "Said of a Git list that follows the disk as it changes."
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
      } else if let branchReport {
        // The age is said, never implied: this is what was read, not a live view.
        TimelineView(.periodic(from: .now, by: 10)) { context in
          Text(age(of: checkedAt?() ?? branchReport.readAt, at: context.date))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      if let refresh {
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .help(Text("Read the repositories again", bundle: .module))
          .accessibilityLabel(Text("Read the repositories again", bundle: .module))
      }
    }
  }

  /// Every repository of the report watched, and read without failing since.
  private var isLive: Bool {
    guard let branchReport, !branchReport.repositories.isEmpty else { return false }
    return branchReport.repositories.allSatisfy { statuses[$0.path]?.phase == .fresh }
  }
}

/// The first line of the notes, or that there are none.
private struct NotesSummary: View {
  let document: NotesDocument

  var body: some View {
    if let line = document.text.split(whereSeparator: \.isNewline).first {
      Text(verbatim: String(line))
    } else if document.isLoaded {
      Text("Empty", bundle: .module, comment: "Said of a session's notes that hold nothing.")
    }
  }
}

/// What the agent ran for, said once the usage is folded.
private struct UsageSummary: View {
  let session: SessionID
  let usage: UsageModel

  var body: some View {
    if let figures = usage.sessionUsage[session] {
      Text(UsagePresentation.duration(figures.total.runningTime))
    }
  }
}

/// Keeps the usage of the session read while its section is shown, folded or not, and says when
/// it is being read.
private struct UsageWatcher: View {
  let session: SessionID
  let usage: UsageModel

  var body: some View {
    Group {
      if usage.isReading {
        ProgressView().controlSize(.mini)
          .accessibilityLabel(Text("Reading transcripts", bundle: .module))
      } else {
        Color.clear.frame(width: 0, height: 0)
      }
    }
    .onAppear { usage.startWatching(session) }
    .onDisappear { usage.stopWatching(session) }
    // The inspector keeps this view when another session is selected.
    .onChange(of: session) { previous, next in
      usage.stopWatching(previous)
      usage.startWatching(next)
    }
  }
}

// MARK: - Git

private struct GitPane: View {
  let session: WorkSession
  let branchReport: SessionBranchReport?
  let statuses: [String: RepositoryStatusState]
  let sessionNames: [SessionID: String]
  let refresh: (() -> Void)?
  let openPrivacySettings: (() -> Void)?
  @Bindable var git: GitInspectorModel
  /// ⌘⇧R belongs to the list only while it has the focus: in the terminal, it is the agent's.
  @FocusState private var isListFocused: Bool

  private var groups: [RepositoryGroupPresentation] {
    (branchReport?.repositories ?? []).map {
      git.group(for: $0, state: statuses[$0.path], sessionNames: sessionNames)
    }
  }

  var body: some View {
    let groups = groups
    let pane = GitPanePresentation(
      groups: groups, plainFolders: git.plainFolders(of: session, report: branchReport))
    List(selection: selection) {
      Section {
        if let notice = git.notice {
          Label(notice, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let shared = pane.sharedIssue {
          IssueBannerView(banner: shared, actions: bannerActions)
        }
        emptyOrLoading(pane)
        if let allClean = pane.allClean {
          Text(allClean)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(groups) { group in
          RepositoryGroupView(
            group: group,
            session: session.id,
            git: git,
            showsBanner: pane.sharedIssue == nil,
            bannerActions: bannerActions
          )
        }
        ForEach(pane.plainFolders, id: \.self) { folder in
          PlainFolderRow(path: folder) { git.revealRepository(folder) }
        }
        if let visited = branchReport?.visitedOnly, !visited.isEmpty {
          Text(
            "Also looked in: \(visited.joined(separator: ", "))", bundle: .module,
            comment: "A list of folders the agent visited that are not repositories."
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .listStyle(.sidebar)
    .focused($isListFocused)
    .onChange(of: git.focusRequest) { takeFocus() }
    // A turn later: a list that has just appeared does not take the keyboard yet.
    .onAppear { if git.isFocusPending { Task { @MainActor in takeFocus() } } }
    .accessibilityIdentifier("inspector-git")
    .contextMenu(forSelectionType: GitInspectorRowID.self) { ids in
      if let id = ids.first {
        FileRowMenu(id: id, row: row(id, in: groups), git: git)
      }
    } primaryAction: { ids in
      guard let id = ids.first else { return }
      Task { await git.activate(id) }
    }
    .background {
      // ⌘⇧R reveals the selected file. Present only with a selection, so the shortcut belongs to
      // no one the rest of the time.
      if isListFocused, let selected = git.selection(in: session.id) {
        Button {
          git.reveal(selected)
        } label: {
          Text("Reveal in Finder", bundle: .module)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
    }
  }

  private func takeFocus() {
    isListFocused = true
    git.focusTaken()
  }

  private var selection: Binding<GitInspectorRowID?> {
    Binding(
      get: { git.selection(in: session.id) },
      set: { git.select($0, in: session.id) }
    )
  }

  private var bannerActions: IssueBannerView.Actions {
    IssueBannerView.Actions(
      refresh: refresh,
      reveal: { git.revealRepository($0) },
      openPrivacySettings: openPrivacySettings,
      copy: { git.copy($0) }
    )
  }

  private func row(_ id: GitInspectorRowID, in groups: [RepositoryGroupPresentation]) -> FileRow? {
    if let child = id.child {
      return FileRow(repositoryPath: id.repositoryPath, directory: id.path, child: child)
    }
    return groups.first { $0.repositoryPath == id.repositoryPath }?
      .sections.first { $0.column == id.column }?
      .rows.first { $0.id == id }
  }

  @ViewBuilder
  private func emptyOrLoading(_ pane: GitPanePresentation) -> some View {
    if let branchReport {
      if pane.groups.isEmpty {
        Group {
          if !branchReport.hasTranscript {
            Text(
              "No transcript of this session was found, so only what is attached can be shown.",
              bundle: .module)
          } else if session.repositories.isEmpty {
            Text("No repository in this session yet.", bundle: .module)
          } else {
            Text("No repository worked in yet.", bundle: .module)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
      }
    } else if refresh != nil {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Reading the repositories…", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      InspectorPlaceholder(
        session.repositories.isEmpty
          ? LocalizedStringResource("No repository in this session yet.", bundle: .module)
          : LocalizedStringResource("Git is not read in this window.", bundle: .module))
    }
  }

}

/// A check, not a reading: the report is read again only when the disk moved, and checked at
/// every reading.
private func age(of date: Date, at now: Date) -> String {
  let seconds = max(0, Int(now.timeIntervalSince(date)))
  if seconds < 10 {
    return String(
      localized: "checked just now", bundle: .module,
      comment: "When the Git list was last checked against the disk.")
  }
  if seconds < 60 {
    return String(
      localized: "checked \(seconds / 10 * 10) s ago", bundle: .module,
      comment: "When the Git list was last checked against the disk: a number of seconds.")
  }
  return String(
    localized: "checked at \(date.formatted(date: .omitted, time: .shortened))", bundle: .module,
    comment: "When the Git list was last checked against the disk: a time of day.")
}

/// One repository: its header, then its lists. Equatable on what it draws, so that a selection
/// moving in the pane does not have every group compare its rows again.
///
/// Never wrapped in `.equatable()`: an `EquatableView` stands between the list and the
/// `DisclosureGroup`, which then no longer knows it is an outline row, falls back to a stack, and
/// SwiftUI stops the application on its first draw (`_DisclosureGroupContainer … may not have
/// Body == Never`). SwiftUI compares an `Equatable` view with `==` on its own.
private struct RepositoryGroupView: View, Equatable {
  let group: RepositoryGroupPresentation
  let session: SessionID
  let git: GitInspectorModel
  let showsBanner: Bool
  let bannerActions: IssueBannerView.Actions
  /// The actions are closures, which cannot be compared: which of them the banner offers is.
  private let offeredActions: [Bool]

  init(
    group: RepositoryGroupPresentation, session: SessionID, git: GitInspectorModel,
    showsBanner: Bool, bannerActions: IssueBannerView.Actions
  ) {
    self.group = group
    self.session = session
    self.git = git
    self.showsBanner = showsBanner
    self.bannerActions = bannerActions
    offeredActions = [bannerActions.refresh != nil, bannerActions.openPrivacySettings != nil]
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.group == rhs.group && lhs.session == rhs.session && lhs.git === rhs.git
      && lhs.showsBanner == rhs.showsBanner && lhs.offeredActions == rhs.offeredActions
  }

  var body: some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { git.isExpanded(group, in: session) },
        set: { git.setExpanded(group.repositoryPath, $0, in: session) }
      )
    ) {
      if showsBanner, let banner = group.banner {
        IssueBannerView(banner: banner, actions: bannerActions)
      }
      if let asOf = group.asOf, group.hasChanges || group.committedCount > 0 {
        Text(
          "As of \(asOf.formatted(date: .omitted, time: .shortened))", bundle: .module,
          comment: "The time of day the list shown was true."
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      if group.isUnreadable {
        Button {
          git.revealRepository(group.repositoryPath)
        } label: {
          Text("Reveal in Finder", bundle: .module)
        }
        .buttonStyle(.link)
        .font(.caption)
      }
      ForEach(group.sections) { section in
        FileSectionView(
          section: section, session: session, git: git, isStale: group.asOf != nil)
      }
      if group.isTruncated {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            "Only the first \(group.changeCount) changes are listed; the counts are exact.",
            bundle: .module
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            git.revealRepository(group.repositoryPath)
          } label: {
            Text("Reveal in Finder", bundle: .module)
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
    } label: {
      RepositoryHeader(group: group)
        .contextMenu {
          Button {
            git.revealRepository(group.repositoryPath)
          } label: {
            Text("Reveal in Finder", bundle: .module)
          }
          if let editor = git.editorName {
            Button {
              Task { await git.openRepository(group.repositoryPath) }
            } label: {
              Text("Open in \(editor)", bundle: .module, comment: "An editor's name: Xcode.")
            }
          }
          Divider()
          Button {
            git.copy(group.repositoryPath)
          } label: {
            Text("Copy Path", bundle: .module)
          }
        }
    }
  }
}

private struct RepositoryHeader: View {
  let group: RepositoryGroupPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(group.title)
          .font(.callout.weight(.semibold))
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
        if let worktree = group.worktree {
          Text(worktree)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        count
      }
      .help(group.repositoryPath)

      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption)
          .foregroundStyle(.secondary)
        // Whole, on as many lines as it takes: a branch cut in its middle is a branch nobody
        // can recognise.
        Text(group.branch.text)
          .font(.caption.monospaced())
          .foregroundStyle(isNamed ? .primary : .secondary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        ForEach(group.pills, id: \.label) { pill in
          Pill(pill.label, color: pill.tone.color)
        }
        if let arrows = group.arrows {
          Text(arrows)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help(group.distanceHelp)
        }
      }

      if let operation = group.operation {
        Label(operation, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Text(group.summary)
        .font(.caption)
        .foregroundStyle(group.asOf == nil ? .secondary : .tertiary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(group.details, id: \.self) { detail in
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(group.accessibilityLabel)
  }

  private var isNamed: Bool {
    if case .named = group.branch { return true }
    return false
  }

  @ViewBuilder
  private var count: some View {
    if group.isLoading {
      ProgressView()
        .controlSize(.mini)
        .accessibilityLabel(Text("Reading", bundle: .module))
    } else if group.hasChanges {
      Text(verbatim: group.isTruncated ? "\(group.changeCount)+" : "\(group.changeCount)")
        .font(.caption.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
        .help(Text("\(group.changeCount) changed entries", bundle: .module))
    }
  }
}

private struct FileSectionView: View {
  let section: FileSection
  let session: SessionID
  let git: GitInspectorModel
  let isStale: Bool

  var body: some View {
    let limit = git.rowLimit(section.id, in: session)
    DisclosureGroup(
      isExpanded: Binding(
        get: { git.isExpanded(section, in: session) },
        set: { git.setExpanded(section.id, $0, in: session) }
      )
    ) {
      ForEach(section.rows.prefix(limit)) { row in
        FileRowView(row: row, isStale: isStale, directory: directoryControl(for: row))
          .tag(row.id)
        if row.isDirectory, git.isExpanded(directory: row.id, in: session) {
          DirectoryContents(row: row, listing: git.listing(of: row.id, in: session))
        }
      }
      if let total = section.totalCount, total > section.rows.count, section.rows.count <= limit {
        Text("and \(total - section.rows.count) more, not listed", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if section.rows.count > limit {
        HStack(spacing: 10) {
          Button {
            git.showMore(section.id, in: session)
          } label: {
            Text(
              "Show \(min(GitInspectorModel.pageSize, section.rows.count - limit)) More",
              bundle: .module)
          }
          Button {
            git.showAll(section.id, in: session)
          } label: {
            Text(
              "Show All (\(section.rows.count))", bundle: .module,
              comment: "Shows every file of a list: their number.")
          }
        }
        .buttonStyle(.link)
        .font(.caption)
      }
    } label: {
      HStack(spacing: 4) {
        Text(section.column.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(verbatim: "\(section.totalCount ?? section.rows.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      .help(section.help ?? "")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        [
          "\(String(localized: section.column.title)), \(section.totalCount ?? section.rows.count)",
          section.help,
        ]
        .compactMap { $0 }.joined(separator: ", "))
    }
  }

  private func directoryControl(for row: FileRow) -> DirectoryControl? {
    guard row.isDirectory, row.id.child == nil else { return nil }
    let isExpanded = git.isExpanded(directory: row.id, in: session)
    return DirectoryControl(isExpanded: isExpanded) {
      git.setExpanded(directory: row.id, !isExpanded, in: session)
    }
  }
}

private struct DirectoryControl {
  let isExpanded: Bool
  let toggle: () -> Void
}

/// The files of an unfolded untracked folder, under it.
private struct DirectoryContents: View {
  let row: FileRow
  let listing: DirectoryListingState?

  var body: some View {
    switch listing {
    case .loaded(let listing):
      ForEach(listing.paths, id: \.self) { child in
        FileRowView(
          row: FileRow(repositoryPath: row.id.repositoryPath, directory: row.id.path, child: child),
          isStale: false, directory: nil
        )
        .padding(.leading, 14)
        .tag(
          GitInspectorRowID(
            repositoryPath: row.id.repositoryPath, column: .untracked, path: row.id.path,
            child: child))
      }
      if listing.isTruncated {
        Text("and \(listing.totalCount - listing.paths.count) more", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 14)
      }
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.leading, 14)
    case .loading, nil:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Reading…", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 14)
    }
  }
}

private struct FileRowView: View {
  let row: FileRow
  let isStale: Bool
  let directory: DirectoryControl?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(row.letter)
        .font(.caption.monospaced().weight(.bold))
        .foregroundStyle(row.tone.color)
        .frame(minWidth: 16, alignment: .leading)
      if row.isSubmodule {
        Image(systemName: "shippingbox")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 3) {
          Text(row.name)
            .font(.callout)
            .strikethrough(!row.isOnDisk, color: .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let renamedFrom = row.renamedFrom {
            Text(verbatim: "← \(renamedFrom)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if let folder = row.directory {
          Text(folder)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 2)
      if !row.isAttributed {
        Image(systemName: "questionmark.circle")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .help(FileRow.unattributedHelp)
      }
      if let directory {
        Button(action: directory.toggle) {
          Image(systemName: directory.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(
          directory.isExpanded
            ? Text("Hide the files of this folder", bundle: .module)
            : Text("Show the files of this folder", bundle: .module)
        )
        .accessibilityLabel(
          directory.isExpanded
            ? Text("Hide files", bundle: .module) : Text("Show files", bundle: .module))
      }
    }
    .opacity(isStale ? 0.6 : 1)
    .help(row.help)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
  }
}

private struct FileRowMenu: View {
  let id: GitInspectorRowID
  let row: FileRow?
  let git: GitInspectorModel

  var body: some View {
    let isOnDisk = row?.isOnDisk ?? true
    Button {
      git.reveal(id)
    } label: {
      if isOnDisk {
        Text("Reveal in Finder", bundle: .module)
      } else {
        Text("Reveal Folder in Finder", bundle: .module)
      }
    }
    if let editor = git.editorName {
      Button {
        Task { await git.activate(id) }
      } label: {
        Text("Open in \(editor)", bundle: .module, comment: "An editor's name: Xcode.")
      }
      .disabled(!isOnDisk || row?.isDirectory == true)
    }
    Button {
      Task { await git.openWithDefaultApplication(id) }
    } label: {
      Text("Open with Default Application", bundle: .module)
    }
    .disabled(!isOnDisk || row?.isDirectory == true)
    Divider()
    Button {
      git.copyPath(id, relative: false)
    } label: {
      Text("Copy Path", bundle: .module)
    }
    Button {
      git.copyPath(id, relative: true)
    } label: {
      Text("Copy Relative Path", bundle: .module)
    }
  }
}

private struct PlainFolderRow: View {
  let path: String
  let reveal: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label((path as NSString).lastPathComponent, systemImage: "folder")
        .lineLimit(1)
      Text(
        "Not a Git repository. The repositories the agent works in inside it appear above.",
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
    }
    .help(path)
    .contextMenu {
      Button(action: reveal) { Text("Reveal in Finder", bundle: .module) }
    }
    .accessibilityElement(children: .combine)
  }
}

/// A failure, on its repository's line: the sentence, what to do, the command to copy and the one
/// button that helps. The age of a lock is said again as it grows.
private struct IssueBannerView: View {
  struct Actions {
    let refresh: (() -> Void)?
    let reveal: (String) -> Void
    let openPrivacySettings: (() -> Void)?
    let copy: (String) -> Void
  }

  let banner: IssueBanner
  let actions: Actions

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      VStack(alignment: .leading, spacing: 4) {
        Label(banner.issue.message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
        if let suggestion = banner.suggestion {
          Text(suggestion)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let command = banner.command {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Selectable, to be copied: the application never runs it.
            Text(command)
              .font(.caption2.monospaced())
              .textSelection(.enabled)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
            Button {
              actions.copy(command)
            } label: {
              Text("Copy", bundle: .module, comment: "Copies a command line.")
            }
            .buttonStyle(.link)
            .font(.caption2)
          }
        }
        action
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private var action: some View {
    switch banner.action {
    case .refresh:
      if let refresh = actions.refresh {
        Button(action: refresh) {
          Text("Refresh", bundle: .module, comment: "Reads the repository again.")
        }
        .buttonStyle(.link)
        .font(.caption)
      }
    case .revealParent(let folder):
      Button {
        actions.reveal(folder)
      } label: {
        Text("Reveal Parent Folder", bundle: .module)
      }
      .buttonStyle(.link)
      .font(.caption)
    case .openPrivacySettings:
      if let open = actions.openPrivacySettings {
        Button(action: open) {
          Text("Open Privacy Settings", bundle: .module)
        }
        .buttonStyle(.link)
        .font(.caption)
      }
    }
  }
}

extension ChangeTone {
  fileprivate var color: Color {
    switch self {
    case .added: return .green
    case .modified: return .orange
    case .deleted: return .red
    case .renamed: return .blue
    case .conflicted: return .red
    case .untracked: return .secondary
    }
  }
}

extension RepositoryGroupPresentation.Pill.Tone {
  fileprivate var color: Color {
    switch self {
    case .new: return .green
    case .advanced: return .blue
    case .rewritten: return .orange
    case .unreadable: return .secondary
    }
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

// MARK: - Session

private struct AgentRow: View {
  let agent: SessionAgentConfiguration?
  let resolution: SessionAgentResolution?
  let names: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let agent {
        Label(AgentHistoryList.label(agent, names: names), systemImage: "cpu")
          .lineLimit(1)
      } else {
        Label {
          Text("No agent recorded", bundle: .module)
        } icon: {
          Image(systemName: "cpu")
        }
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
      return String(localized: "Ready to resume.", bundle: .module)
    case .unavailable(let diagnostic):
      return diagnostic.summary
    case .unknownProvider(let providerID):
      return String(
        localized: "The provider \(providerID) is not installed in this build.", bundle: .module,
        comment: "An agent's identifier: claude-code, codex.")
    case .unassigned:
      return String(localized: "This session was stored without an agent.", bundle: .module)
    case .none:
      return String(localized: "Detection has not answered yet.", bundle: .module)
    }
  }
}

/// Every agent the session had, newest first: each switch, the failed ones included, and where it
/// started.
private struct AgentHistoryList: View {
  let session: WorkSession
  let names: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("History", bundle: .module, comment: "The agents a session had, heading.")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(session.agentHistory.reversed()) { change in
        entry(change)
      }
      if let first = firstAgent, let start = session.startedAt {
        row(
          date: start,
          text: String(
            localized: "Started with \(Self.label(first, names: names))", bundle: .module,
            comment: "The agent a session first ran: its name, and its model."),
          detail: nil,
          failed: false,
          spoken: String(
            localized:
              "\(Self.spoken(start)), started with \(Self.label(first, names: names))",
            bundle: .module,
            comment: "What VoiceOver says of a session's start: a date, then its first agent.")
        )
      }
    }
    .padding(.vertical, 2)
  }

  /// The agent that first ran: the one the first real switch left, or the current one. A switch
  /// made before the session ever ran does not count — the agent it left never started.
  private var firstAgent: SessionAgentConfiguration? {
    session.agentHistory.first(where: \.leftAgentThatRan)?.previous ?? session.agent
  }

  @ViewBuilder
  private func entry(_ change: AgentChange) -> some View {
    let from = Self.label(change.previous, names: names)
    // Another model of the same agent names the model alone: the agent is already on the line.
    let to =
      change.changesProvider
      ? Self.label(change.next, names: names)
      : (change.next.modelID
        ?? String(
          localized: "default model", bundle: .module,
          comment: "Stands for the model an agent uses when none is chosen."))
    switch change.outcome {
    case .completed:
      row(
        date: change.date,
        text: "\(from) → \(to)",
        detail: Self.handover(change.handover),
        failed: false,
        spoken: String(
          localized:
            "\(Self.spoken(change.date)), switched from \(from) to \(to), \(Self.handover(change.handover))",
          bundle: .module,
          comment:
            "What VoiceOver says of an agent switch: a date, the agent left, the agent taken, and what was handed over."
        )
      )
    case .failed(let reason):
      row(
        date: change.date,
        text: String(
          localized: "→ \(to) failed", bundle: .module,
          comment: "A switch to this agent that failed."),
        detail: reason.isEmpty ? nil : reason,
        failed: true,
        spoken: String(
          localized: "\(Self.spoken(change.date)), switch to \(to) failed. \(reason)",
          bundle: .module,
          comment: "What VoiceOver says of a failed agent switch: a date, the agent, and why.")
      )
    }
  }

  private func row(
    date: Date, text: String, detail: String?, failed: Bool, spoken: String
  ) -> some View {
    // The change first and whole, on as many lines as it takes; when and how below it.
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        if failed {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        Text(text)
          .foregroundStyle(failed ? Color.orange : .primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.caption)
      Text(
        [date.formatted(date: .abbreviated, time: .shortened), detail]
          .compactMap { $0 }.joined(separator: " · ")
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  static func label(_ agent: SessionAgentConfiguration, names: [String: String]) -> String {
    let name = names[agent.providerID] ?? agent.providerID
    return agent.modelID.map { "\(name) · \($0)" } ?? name
  }

  static func handover(_ handover: AgentChange.Handover) -> String {
    switch handover {
    case .resumedConversation:
      return String(
        localized: "same conversation", bundle: .module,
        comment: "What an agent switch handed over: the conversation was resumed.")
    case .summary(let bytes, _, let wasEdited):
      let size = AgentSwitchSheet.size(bytes)
      return wasEdited
        ? String(
          localized: "edited summary, \(size)", bundle: .module,
          comment: "What an agent switch handed over: a size, “1.2 KiB”.")
        : String(
          localized: "summary, \(size)", bundle: .module,
          comment: "What an agent switch handed over: a size, “1.2 KiB”.")
    case .initialPrompt:
      return String(
        localized: "initial prompt", bundle: .module,
        comment: "What an agent switch handed over.")
    case .nothing:
      return String(
        localized: "nothing handed over", bundle: .module,
        comment: "What an agent switch handed over.")
    }
  }

  private static func spoken(_ date: Date) -> String {
    date.formatted(date: .long, time: .shortened)
  }
}

private struct InspectorPlaceholder: View {
  private let text: LocalizedStringResource

  init(_ text: LocalizedStringResource) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
  }
}
