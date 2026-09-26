import SwiftUI
import VibeApplication
import VibeDomain

/// The sidebar as a task board (#80): four columns behind four tabs, and a swipe on a row to move
/// its session to another one. Grouped by folder (#27), the column on screen is cut into one
/// foldable section per working folder; the swipe works the same in every section.
///
/// Only the column on screen is a list. A swipe slides the row under the fingers aside, and
/// uncovers the buttons of the statuses next to its own; the rest of the column does not move. A
/// click on one moves the session, and the column on screen stays where it is.
struct SessionSidebar: View {
  @Bindable var model: AppModel
  /// Focus Sidebar, ⌥⌘1, gives the list the keyboard.
  @FocusState private var isListFocused: Bool
  @State private var swipe: SessionSwipe?
  /// Where a drag started from, for a swipe made with the pointer.
  @State private var dragBase: CGFloat?
  /// A drag that started vertical, and stays a drag of the list whatever it does next.
  @State private var isDragDeclined = false
  /// The row under the pointer, for when the table cannot say which row is under the fingers.
  @State private var hoveredSessionID: SessionID?
  @State private var isShowingArchive = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      ColumnTabs(model: model)
      columns
      Divider()
      ArchivedSessionsBar(model: model, isShowingArchive: $isShowingArchive)
      Divider()
      SidebarFooter(model: model)
    }
    .searchable(
      text: Binding(get: { model.filter.searchText }, set: { model.setSearchText($0) }),
      placement: .sidebar,
      prompt: Text("Search sessions", bundle: .module)
    )
    .onChange(of: model.filter.column) { closeSwipe(animated: false) }
    // Rows that move under a still pointer do not say so: the hover is only trusted again once
    // the pointer moves.
    .onChange(of: model.visibleSessions.map(\.id)) { hoveredSessionID = nil }
    .onChange(of: model.selectedSessionID) { _, id in
      if swipe != nil, swipe?.sessionID != id { closeSwipe(animated: true) }
    }
  }

  // MARK: - Columns

  private var columns: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      list(width: width)
        .frame(width: width, height: geometry.size.height, alignment: .topLeading)
        .background(
          HorizontalSwipeMonitor(
            began: { row in beginTrackpadSwipe(row: row, width: width) },
            changed: { delta in swipe?.translation += delta },
            ended: { settleSwipe() },
            interrupted: { closeSwipe(animated: true) }
          )
        )
    }
  }

  private func list(width: CGFloat) -> some View {
    // Only the rows a shortcut can reach claim one, numbered in the order they are drawn.
    let positions = Dictionary(
      uniqueKeysWithValues: model.displayedSessions.prefix(AppModel.shortcutPositionLimit)
        .enumerated().map { ($0.element.id, $0.offset + 1) })
    return List(
      selection: Binding(get: { model.selectedSessionID }, set: { model.selectFromList($0) })
    ) {
      switch model.sidebarContent {
      case .flat(let sessions):
        rows(sessions, positions: positions, width: width)
      case .grouped(let groups):
        ForEach(groups) { group in
          Section(
            isExpanded: Binding(
              get: { model.isExpanded(group) },
              set: { model.setExpanded($0, group: group) })
          ) {
            rows(group.sessions, positions: positions, width: width)
          } header: {
            SessionGroupHeader(model: model, group: group)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .animation(reduceMotion ? nil : .snappy, value: model.visibleSessions.map(\.id))
    .focused($isListFocused)
    .onChange(of: model.sidebarFocusRequest) { isListFocused = true }
    .onKeyPress(.escape) {
      guard swipe != nil else { return .ignored }
      closeSwipe(animated: true)
      return .handled
    }
    .accessibilityLabel(Text("Sessions", bundle: .module))
    .accessibilityIdentifier("session-list")
    .alert(
      Text("The group could not be renamed.", bundle: .module),
      isPresented: Binding(
        get: { model.folderLabelFailure != nil },
        set: { if !$0 { model.dismissFolderLabelFailure() } })
    ) {
      Button(LocalizedStringResource("OK", bundle: .module)) { model.dismissFolderLabelFailure() }
    } message: {
      Text(verbatim: model.folderLabelFailure ?? "")
    }
    .overlay {
      if model.visibleSessions.isEmpty {
        emptyState
      }
    }
  }

  private func rows(
    _ sessions: [WorkSession], positions: [SessionID: Int], width: CGFloat
  ) -> some View {
    ForEach(sessions) { session in
      row(for: session, position: positions[session.id], width: width)
        .tag(session.id)
    }
  }

  private func row(for session: WorkSession, position: Int?, width: CGFloat) -> some View {
    let isSwiped = swipe?.sessionID == session.id
    let commands = SessionCommands(model: model, session: session)
    return SessionRow(
      session: session,
      icon: model.icons.image(for: session.appearance.iconID),
      status: model.statusPresentation(for: session),
      isRestoring: model.isRestoring(session.id),
      webView: model.webViewAttention(for: session.id),
      shortcutPosition: position,
      commands: commands
    )
    // Only the swiped row moves, out of the way of its buttons. With Reduce Motion it stays,
    // and the buttons fade in over it.
    .offset(x: isSwiped && !reduceMotion ? swipe?.offset ?? 0 : 0)
    .overlay(alignment: .leading) {
      if isSwiped, let swipe, swipe.offset > 0 {
        SwipeButtons(
          statuses: swipe.leading.reversed(),
          width: reduceMotion ? swipe.leadingButtonsWidth : swipe.revealedButtonsWidth,
          opacity: reduceMotion ? swipe.progress : 1,
          choose: { commit($0, for: session.id) }
        )
      }
    }
    .overlay(alignment: .trailing) {
      if isSwiped, let swipe, swipe.offset < 0 {
        SwipeButtons(
          statuses: swipe.trailing,
          width: reduceMotion ? swipe.trailingButtonsWidth : swipe.revealedButtonsWidth,
          opacity: reduceMotion ? swipe.progress : 1,
          choose: { commit($0, for: session.id) }
        )
      }
    }
    .onHover { isHovering in
      if isHovering {
        hoveredSessionID = session.id
      } else if hoveredSessionID == session.id {
        hoveredSessionID = nil
      }
    }
    .simultaneousGesture(drag(for: session, width: width))
    // A click on the open row puts its buttons away, as a click anywhere else does.
    .simultaneousGesture(
      TapGesture().onEnded {
        if isSwiped { closeSwipe(animated: true) }
      })
  }

  // MARK: - Swipe

  private func makeSwipe(for session: WorkSession, width: CGFloat) -> SessionSwipe {
    SessionSwipe(
      sessionID: session.id,
      leading: model.previousTaskStatuses(of: session),
      trailing: model.nextTaskStatuses(of: session),
      availableWidth: width
    )
  }

  /// - Parameter row: the row of the table under the fingers, as `tableRows` numbers them. The
  ///   hover is only asked when the table could not say.
  private func beginTrackpadSwipe(row: Int?, width: CGFloat) -> Bool {
    let visible = model.visibleSessions
    let session: WorkSession?
    if let row {
      let rows = tableRows
      let id = rows.indices.contains(row) ? rows[row] : nil
      session = id.flatMap { id in visible.first { $0.id == id } }
    } else {
      session = hoveredSessionID.flatMap { id in visible.first { $0.id == id } }
    }
    guard let session else { return false }
    // A swipe on the row already open takes it from where it is.
    if swipe?.sessionID != session.id {
      swipe = makeSwipe(for: session, width: width)
    }
    return true
  }

  /// The session each row of the table draws, in order: a group's header is a row of its own,
  /// with no session to swipe, and the sessions of a folded group are no rows at all.
  private var tableRows: [SessionID?] {
    switch model.sidebarContent {
    case .flat(let sessions):
      return sessions.map(\.id)
    case .grouped(let groups):
      return groups.flatMap { group -> [SessionID?] in
        [nil] + (model.isExpanded(group) ? group.sessions.map(\.id) : [])
      }
    }
  }

  /// The pointer's equivalent: a drag that starts out horizontal.
  private func drag(for session: WorkSession, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard !isDragDeclined else { return }
        if dragBase == nil {
          // Judged once, on the first movement: a drag that starts vertical is the list's.
          guard abs(value.translation.width) > abs(value.translation.height) else {
            isDragDeclined = true
            return
          }
          if swipe?.sessionID != session.id {
            swipe = makeSwipe(for: session, width: width)
          }
          dragBase = swipe?.translation ?? 0
        }
        guard let dragBase else { return }
        swipe?.translation = dragBase + value.translation.width
      }
      .onEnded { _ in
        isDragDeclined = false
        guard dragBase != nil else { return }
        dragBase = nil
        settleSwipe()
      }
  }

  private func settleSwipe() {
    guard let current = swipe else { return }
    let settled = current.settledTranslation
    withAnimation(reduceMotion ? nil : .snappy) {
      if settled == 0 {
        swipe = nil
      } else {
        swipe?.translation = settled
      }
    }
  }

  private func closeSwipe(animated: Bool) {
    guard swipe != nil else { return }
    withAnimation(animated && !reduceMotion ? .snappy : nil) { swipe = nil }
  }

  /// The click that decides. The columns go back as the row leaves for the tab it was sent to.
  private func commit(_ status: SessionTaskStatus, for id: SessionID) {
    closeSwipe(animated: true)
    Task { await model.setTaskStatus(status, for: id) }
  }

  // MARK: - Empty

  /// Two different silences, told apart. "Nothing here" and "nothing matched what you typed"
  /// look identical on screen and mean opposite things, and only one of them has a way out.
  @ViewBuilder
  private var emptyState: some View {
    let column = model.filter.column
    if model.filter.isNarrowing {
      ContentUnavailableView {
        Label(
          LocalizedStringResource("No matching session", bundle: .module),
          systemImage: "line.3.horizontal.decrease.circle")
      } description: {
        Text(
          "No session in \(String(localized: column.label)) matches this filter.",
          bundle: .module, comment: "A task status, the name of a column of the sidebar.")
      } actions: {
        Button(LocalizedStringResource("Clear Filter", bundle: .module)) { model.clearNarrowing() }
      }
    } else {
      ContentUnavailableView {
        Label {
          Text(column.label)
        } icon: {
          Image(systemName: column.symbolName)
            .foregroundStyle(column.tint)
        }
      } description: {
        Text(emptyDescription(for: column))
      }
    }
  }

  private func emptyDescription(for column: SessionTaskStatus) -> LocalizedStringResource {
    switch column {
    case .todo:
      return LocalizedStringResource(
        "Nothing planned. A session added to To Do waits here until you start it.",
        bundle: .module)
    case .doing:
      return LocalizedStringResource(
        "Nothing in progress. Press ⌘N to start a session.", bundle: .module)
    case .waiting:
      return LocalizedStringResource(
        "Nothing is waiting on a review, a build or someone else.", bundle: .module)
    case .done, .archived:
      return LocalizedStringResource(
        "Nothing done yet. Swipe a session to move it here.", bundle: .module)
    }
  }
}

// MARK: - Tabs

/// The four columns, each with its colour, its symbol and how many sessions it holds. A tab not
/// on screen shows an orange dot when one of its sessions waits for the user: the column hides the
/// row that would have said it.
private struct ColumnTabs: View {
  let model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 5) {
      HStack(spacing: 2) {
        ForEach(SessionTaskStatus.columns, id: \.self) { column in
          tab(column)
        }
      }
      .padding(2)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

      GeometryReader { geometry in
        let tabWidth = geometry.size.width / CGFloat(SessionTaskStatus.columns.count)
        Capsule()
          .fill(indicatorColor)
          .frame(width: tabWidth - 16, height: 2)
          .offset(x: CGFloat(index) * tabWidth + 8)
          .animation(reduceMotion ? nil : .snappy, value: index)
      }
      .frame(height: 2)
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 10)
    .padding(.top, 6)
    .padding(.bottom, 4)
  }

  private var index: Int {
    SessionTaskStatus.columns.firstIndex(of: model.filter.column) ?? 0
  }

  private var indicatorColor: Color {
    SessionTaskStatus.columns[index].tint
  }

  private func tab(_ column: SessionTaskStatus) -> some View {
    let summary = model.summary(of: column)
    let isSelected = model.filter.column == column
    return Button {
      model.setColumn(column)
    } label: {
      VStack(spacing: 1) {
        HStack(spacing: 3) {
          Image(systemName: column.symbolName)
            .foregroundStyle(column.tint)
          Text(verbatim: "\(summary.count)")
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .font(.caption.weight(.semibold))
        Text(column.label)
          .font(.caption2)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
      .background(
        isSelected ? column.tint.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay(alignment: .topTrailing) {
        if summary.needsAttention, !isSelected {
          Circle()
            .fill(.orange)
            .frame(width: 6, height: 6)
            .padding(4)
        }
      }
      .contentShape(Rectangle())
      .animation(reduceMotion ? nil : .snappy, value: summary.count)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel(for: column, summary: summary))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("column-tab-\(column.rawValue)")
  }

  private func accessibilityLabel(for column: SessionTaskStatus, summary: AppModel.ColumnSummary)
    -> Text
  {
    let name = String(localized: column.label)
    return summary.needsAttention
      ? Text(
        "\(name), \(summary.count) sessions, one waits for you", bundle: .module,
        comment: "A column tab: its name, how many sessions it holds.")
      : Text(
        "\(name), \(summary.count) sessions", bundle: .module,
        comment: "A column tab: its name, how many sessions it holds.")
  }
}

// MARK: - Swipe buttons

/// The statuses a swipe uncovered, in their colours. The one nearest the row is the next step.
private struct SwipeButtons: View {
  let statuses: [SessionTaskStatus]
  let width: CGFloat
  let opacity: CGFloat
  let choose: (SessionTaskStatus) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(statuses, id: \.self) { status in
        Button {
          choose(status)
        } label: {
          VStack(spacing: 2) {
            Image(systemName: status.symbolName)
              .font(.body.weight(.semibold))
            Text(status.buttonTitle)
              .font(.caption2.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 2)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(status.tint)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(status.moveTitle))
        .accessibilityIdentifier("swipe-\(status.rawValue)")
      }
    }
    .frame(width: max(0, width))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .opacity(opacity)
  }
}

// MARK: - Archived

/// The quiet way in to the archived sessions: a line at the foot of the sidebar, and a list with
/// Unarchive. Archived is a status, not a column: nothing there is being worked on.
private struct ArchivedSessionsBar: View {
  let model: AppModel
  @Binding var isShowingArchive: Bool

  var body: some View {
    Button {
      isShowingArchive.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: SessionTaskStatus.archived.symbolName)
          .foregroundStyle(SessionTaskStatus.archived.tint)
        // Counted as the tabs count: what the list will show, search included.
        Text(
          "Archived (\(model.archivedSessions.count))", bundle: .module,
          comment: "The line at the foot of the sidebar that opens the archived sessions.")
        Spacer(minLength: 0)
      }
      .font(.caption)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityIdentifier("archived-sessions")
    .popover(isPresented: $isShowingArchive, arrowEdge: .trailing) {
      ArchivedSessionsList(model: model)
    }
  }
}

private struct ArchivedSessionsList: View {
  let model: AppModel

  var body: some View {
    let archived = model.archivedSessions
    Group {
      if archived.isEmpty {
        ContentUnavailableView {
          Label(
            LocalizedStringResource("No archived session", bundle: .module),
            systemImage: SessionTaskStatus.archived.symbolName)
        } description: {
          Text(
            "Sessions archived from Done land here. Nothing is ever deleted.", bundle: .module)
        }
      } else {
        List(archived) { session in
          HStack(spacing: 8) {
            SessionBadge(appearance: session.appearance)
            VStack(alignment: .leading, spacing: 1) {
              Text(session.name)
                .lineLimit(1)
              if let archivedAt = session.archivedAt {
                Text(archivedAt, style: .date)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 6)
            Button(LocalizedStringResource("Unarchive", bundle: .module)) {
              Task { await model.restore(session.id) }
            }
            .controlSize(.small)
          }
          .contentShape(Rectangle())
          .onTapGesture { model.showArchived(session.id) }
          .accessibilityAction(named: Text("Show", bundle: .module)) {
            model.showArchived(session.id)
          }
        }
        .listStyle(.plain)
      }
    }
    .frame(width: 320, height: 300)
  }
}
