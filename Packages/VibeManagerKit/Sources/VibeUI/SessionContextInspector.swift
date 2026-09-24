import SwiftUI
import VibeApplication
import VibeDomain

/// The right column: what this session works on, and with what.
///
/// Two panes, each scrolling on its own: Git above — one group per repository the session works
/// in, with its branch and its changed files — and the session below, its notes first. A list of
/// five thousand files in one scroll with the notes would push the notes out of reach.
///
/// Everything in the Git pane is what Git and the agent's transcript say, in Git's order: the
/// application reveals and opens files, and never acts on Git.
struct SessionContextInspector: View {
  private let session: WorkSession
  private let resolution: SessionAgentResolution?
  private let branchReport: SessionBranchReport?
  private let repositoryStatuses: [String: RepositoryStatusState]
  private let sessionNames: [SessionID: String]
  private let refreshBranches: (() -> Void)?
  private let git: GitInspectorModel
  private let split: Double
  private let splitChanged: (Double) -> Void
  private let openPrivacySettings: (() -> Void)?
  private let agentNames: [String: String]
  private let switchAgent: (() -> Void)?
  private let notes: NotesModel?
  private let leaveNotes: () -> Void
  private let usage: UsageModel?
  private let isDetailsExpanded: Bool
  private let detailsExpandedChanged: (Bool) -> Void

  init(
    session: WorkSession,
    resolution: SessionAgentResolution?,
    branchReport: SessionBranchReport? = nil,
    repositoryStatuses: [RepositoryStatusKey: RepositoryStatusState] = [:],
    sessionNames: [SessionID: String] = [:],
    refreshBranches: (() -> Void)? = nil,
    git: GitInspectorModel,
    split: Double = 0.6,
    splitChanged: @escaping (Double) -> Void = { _ in },
    openPrivacySettings: (() -> Void)? = nil,
    agentNames: [String: String] = [:],
    switchAgent: (() -> Void)? = nil,
    notes: NotesModel? = nil,
    leaveNotes: @escaping () -> Void = {},
    usage: UsageModel? = nil,
    isDetailsExpanded: Bool = true,
    detailsExpandedChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.session = session
    self.notes = notes
    self.leaveNotes = leaveNotes
    self.usage = usage
    self.isDetailsExpanded = isDetailsExpanded
    self.detailsExpandedChanged = detailsExpandedChanged
    self.resolution = resolution
    self.branchReport = branchReport
    var byPath: [String: RepositoryStatusState] = [:]
    for (key, state) in repositoryStatuses where key.sessionID == session.id {
      byPath[key.repositoryPath] = state
    }
    self.repositoryStatuses = byPath
    self.sessionNames = sessionNames
    self.refreshBranches = refreshBranches
    self.git = git
    self.split = split
    self.splitChanged = splitChanged
    self.openPrivacySettings = openPrivacySettings
    self.agentNames = agentNames
    self.switchAgent = switchAgent
  }

  var body: some View {
    InspectorSplit(fraction: split, onChange: splitChanged) {
      GitPane(
        session: session,
        branchReport: branchReport,
        statuses: repositoryStatuses,
        sessionNames: sessionNames,
        refresh: refreshBranches,
        openPrivacySettings: openPrivacySettings,
        git: git
      )
    } bottom: {
      SessionPane(
        session: session, resolution: resolution, agentNames: agentNames,
        switchAgent: switchAgent, notes: notes, leaveNotes: leaveNotes, usage: usage,
        isDetailsExpanded: isDetailsExpanded, detailsExpandedChanged: detailsExpandedChanged)
    }
  }
}

// MARK: - The two panes

/// Two panes and the divider between them, which the user drags. The share given to the top one
/// is the layout's, and is written back once the drag ends — not at every point of it.
private struct InspectorSplit<Top: View, Bottom: View>: View {
  let fraction: Double
  let onChange: (Double) -> Void
  @ViewBuilder let top: Top
  @ViewBuilder let bottom: Bottom

  @State private var dragged: Double?
  @State private var isHovering = false
  /// Whether this handle pushed the resize cursor, so that it pops exactly what it pushed — also
  /// when it disappears under the pointer, and not while a drag carries the pointer off it.
  @State private var cursorPushed = false

  private static var minimumHeight: Double { 120 }
  private static var handleHeight: Double { 7 }

  var body: some View {
    GeometryReader { proxy in
      let total = max(Double(proxy.size.height) - Self.handleHeight, 1)
      let height = Self.topHeight(for: dragged ?? fraction, in: total)
      VStack(spacing: 0) {
        top.frame(height: height)
        handle(total: total)
        bottom.frame(maxHeight: .infinity)
      }
    }
  }

  private func handle(total: Double) -> some View {
    ZStack {
      Color.clear
      Divider()
    }
    .frame(height: Self.handleHeight)
    .contentShape(Rectangle())
    .onHover { inside in
      isHovering = inside
      updateCursor()
    }
    .onDisappear {
      if cursorPushed { NSCursor.pop() }
      cursorPushed = false
    }
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { value in
          let start = Self.topHeight(for: fraction, in: total)
          dragged = Self.bounded((start + Double(value.translation.height)) / total)
        }
        .onEnded { _ in
          if let dragged { onChange(dragged) }
          dragged = nil
          updateCursor()
        }
    )
    .accessibilityElement()
    .accessibilityLabel("Divider between Git and the session")
    .accessibilityValue("\(Int((dragged ?? fraction) * 100)) percent for Git")
    .accessibilityAdjustableAction { direction in
      let step = direction == .increment ? 0.05 : -0.05
      onChange(Self.bounded(fraction + step))
    }
  }

  private func updateCursor() {
    let wanted = isHovering || dragged != nil
    if wanted, !cursorPushed {
      NSCursor.resizeUpDown.push()
      cursorPushed = true
    } else if !wanted, cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }

  private static func bounded(_ value: Double) -> Double {
    WorkspaceLayout.bounded(value, in: WorkspaceLayout.inspectorSplitRange, fallback: 0.6)
  }

  /// Neither pane under its minimum, as long as the column is tall enough for both.
  private static func topHeight(for fraction: Double, in total: Double) -> Double {
    let wanted = total * fraction
    guard total >= minimumHeight * 2 else { return wanted }
    return min(max(wanted, minimumHeight), total - minimumHeight)
  }
}

/// The session's own context: its notes first, taking the room there is, then its agent and the
/// prompt it started from, which fold away.
///
/// Not one `List`: an editor inside a list fights it for the scrolling, and the notes are what
/// this pane is looked at for.
private struct SessionPane: View {
  let session: WorkSession
  let resolution: SessionAgentResolution?
  let agentNames: [String: String]
  let switchAgent: (() -> Void)?
  let notes: NotesModel?
  let leaveNotes: () -> Void
  let usage: UsageModel?
  let isDetailsExpanded: Bool
  let detailsExpandedChanged: (Bool) -> Void

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        if let notes {
          SessionNotesSection(
            session: session, document: notes.document(for: session.id), notes: notes,
            leave: leaveNotes)
        }
        Divider()
        detailsHeader
        if isDetailsExpanded {
          details
            .frame(height: notes == nil ? nil : max(proxy.size.height * 0.45, 60))
            .frame(maxHeight: notes == nil ? .infinity : nil)
        }
      }
    }
  }

  private var detailsHeader: some View {
    Button {
      detailsExpandedChanged(!isDetailsExpanded)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "chevron.right")
          .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
          .font(.caption2.weight(.semibold))
        Text(usage == nil ? "Agent & initial prompt" : "Agent, usage & initial prompt")
          .font(.subheadline.weight(.semibold))
        Spacer()
      }
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityLabel(
      usage == nil ? "Agent and initial prompt" : "Agent, usage and initial prompt"
    )
    .accessibilityValue(isDetailsExpanded ? "Expanded" : "Collapsed")
  }

  private var details: some View {
    List {
      Section {
        AgentRow(agent: session.agent, resolution: resolution, names: agentNames)
        if !session.agentHistory.isEmpty {
          AgentHistoryList(session: session, names: agentNames)
        }
      } header: {
        HStack {
          Text("Agent")
          Spacer()
          if let switchAgent {
            Button("Switch…", action: switchAgent)
              .buttonStyle(.borderless)
              .controlSize(.small)
              .accessibilityLabel("Switch the agent of \(session.name)")
          }
        }
      }

      if let usage {
        SessionUsageSection(session: session, usage: usage, agentNames: agentNames)
      }

      Section("Initial prompt") {
        // The name and revision the session was created with: the template may since have been
        // renamed, changed or deleted, and none of that changes what this session was sent.
        if let template = session.template {
          Text(
            template.revision.map { "From template “\(template.name)”, revision \($0)" }
              ?? "From template “\(template.name)”"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
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
          Text("Also looked in: \(visited.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        header(groups)
      }
    }
    .listStyle(.sidebar)
    .focused($isListFocused)
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
        Button("Reveal in Finder") { git.reveal(selected) }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .opacity(0)
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
    }
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
        Text(
          !branchReport.hasTranscript
            ? "No transcript of this session was found, so only what is attached can be shown."
            : session.repositories.isEmpty
              ? "No repository in this session yet." : "No repository worked in yet."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
      }
    } else if refresh != nil {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Reading the repositories…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      InspectorPlaceholder(
        session.repositories.isEmpty
          ? "No repository in this session yet."
          : "Git is not read in this window.")
    }
  }

  private func header(_ groups: [RepositoryGroupPresentation]) -> some View {
    HStack(spacing: 6) {
      Text("Git")
      Spacer()
      if isLive(groups) {
        // Said only when it is true: every repository is watched and its last reading held.
        Text("live")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      } else if let branchReport {
        // The age is said, never implied: this is what was read, not a live view.
        TimelineView(.periodic(from: .now, by: 10)) { context in
          Text(age(of: branchReport.readAt, at: context.date))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      if let refresh {
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .help("Read the repositories again")
          .accessibilityLabel("Read the repositories again")
      }
    }
  }

  /// Every repository of the report watched, and read without failing since.
  private func isLive(_ groups: [RepositoryGroupPresentation]) -> Bool {
    guard let branchReport, !branchReport.repositories.isEmpty else { return false }
    return branchReport.repositories.allSatisfy { statuses[$0.path]?.phase == .fresh }
  }
}

private func age(of date: Date, at now: Date) -> String {
  let seconds = max(0, Int(now.timeIntervalSince(date)))
  if seconds < 10 { return "read just now" }
  if seconds < 60 { return "read \(seconds / 10 * 10) s ago" }
  return "read at \(date.formatted(date: .omitted, time: .shortened))"
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
        Text("As of \(asOf.formatted(date: .omitted, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      if group.isUnreadable {
        Button("Reveal in Finder") { git.revealRepository(group.repositoryPath) }
          .buttonStyle(.link)
          .font(.caption)
      }
      ForEach(group.sections) { section in
        FileSectionView(
          section: section, session: session, git: git, isStale: group.asOf != nil)
      }
      if group.isTruncated {
        VStack(alignment: .leading, spacing: 2) {
          Text("Only the first \(group.changeCount) changes are listed; the counts are exact.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
          Button("Reveal in Finder") { git.revealRepository(group.repositoryPath) }
            .buttonStyle(.link)
            .font(.caption)
        }
      }
    } label: {
      RepositoryHeader(group: group)
        .contextMenu {
          Button("Reveal in Finder") { git.revealRepository(group.repositoryPath) }
          if let editor = git.editorName {
            Button("Open in \(editor)") {
              Task { await git.openRepository(group.repositoryPath) }
            }
          }
          Divider()
          Button("Copy Path") { git.copy(group.repositoryPath) }
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
        .accessibilityLabel("Reading")
    } else if group.hasChanges {
      Text(group.isTruncated ? "\(group.changeCount)+" : "\(group.changeCount)")
        .font(.caption.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
        .help("\(group.changeCount) changed entries")
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
        Text("and \(total - section.rows.count) more, not listed")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if section.rows.count > limit {
        HStack(spacing: 10) {
          Button("Show \(min(GitInspectorModel.pageSize, section.rows.count - limit)) More") {
            git.showMore(section.id, in: session)
          }
          Button("Show All (\(section.rows.count))") {
            git.showAll(section.id, in: session)
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
        Text("\(section.totalCount ?? section.rows.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      .help(section.help ?? "")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        ["\(section.column.title), \(section.totalCount ?? section.rows.count)", section.help]
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
        Text("and \(listing.totalCount - listing.paths.count) more")
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
        Text("Reading…")
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
            Text("← \(renamedFrom)")
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
          directory.isExpanded ? "Hide the files of this folder" : "Show the files of this folder"
        )
        .accessibilityLabel(directory.isExpanded ? "Hide files" : "Show files")
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
    Button(isOnDisk ? "Reveal in Finder" : "Reveal Folder in Finder") { git.reveal(id) }
    if let editor = git.editorName {
      Button("Open in \(editor)") { Task { await git.activate(id) } }
        .disabled(!isOnDisk || row?.isDirectory == true)
    }
    Button("Open with Default Application") {
      Task { await git.openWithDefaultApplication(id) }
    }
    .disabled(!isOnDisk || row?.isDirectory == true)
    Divider()
    Button("Copy Path") { git.copyPath(id, relative: false) }
    Button("Copy Relative Path") { git.copyPath(id, relative: true) }
  }
}

private struct PlainFolderRow: View {
  let path: String
  let reveal: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label((path as NSString).lastPathComponent, systemImage: "folder")
        .lineLimit(1)
      Text("Not a Git repository. The repositories the agent works in inside it appear above.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
    .help(path)
    .contextMenu { Button("Reveal in Finder", action: reveal) }
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
            Button("Copy") { actions.copy(command) }
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
        Button("Refresh", action: refresh)
          .buttonStyle(.link)
          .font(.caption)
      }
    case .revealParent(let folder):
      Button("Reveal Parent Folder") { actions.reveal(folder) }
        .buttonStyle(.link)
        .font(.caption)
    case .openPrivacySettings:
      if let open = actions.openPrivacySettings {
        Button("Open Privacy Settings", action: open)
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

/// Every agent the session had, newest first: each switch, the failed ones included, and where it
/// started.
private struct AgentHistoryList: View {
  let session: WorkSession
  let names: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("History")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(session.agentHistory.reversed()) { change in
        entry(change)
      }
      if let first = firstAgent, let start = session.startedAt {
        row(
          date: start,
          text: "Started with \(Self.label(first, names: names))",
          detail: nil,
          failed: false,
          spoken: "\(Self.spoken(start)), started with \(Self.label(first, names: names))"
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
      ? Self.label(change.next, names: names) : (change.next.modelID ?? "default model")
    switch change.outcome {
    case .completed:
      row(
        date: change.date,
        text: "\(from) → \(to)",
        detail: Self.handover(change.handover),
        failed: false,
        spoken: "\(Self.spoken(change.date)), switched from \(from) to \(to), "
          + Self.handover(change.handover)
      )
    case .failed(let reason):
      row(
        date: change.date,
        text: "→ \(to) failed",
        detail: reason.isEmpty ? nil : reason,
        failed: true,
        spoken: "\(Self.spoken(change.date)), switch to \(to) failed. \(reason)"
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
      return "same conversation"
    case .summary(let bytes, _, let wasEdited):
      let size = AgentSwitchSheet.size(bytes)
      return wasEdited ? "edited summary, \(size)" : "summary, \(size)"
    case .initialPrompt:
      return "initial prompt"
    case .nothing:
      return "nothing handed over"
    }
  }

  private static func spoken(_ date: Date) -> String {
    date.formatted(date: .long, time: .shortened)
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
