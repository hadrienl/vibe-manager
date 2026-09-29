import AppKit
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
///
/// The swipe is a two-finger scroll, on a trackpad or a Magic Mouse; a row is not dragged with the
/// button held. No SwiftUI gesture sits on the rows: a drag gesture there kept the clicks the list
/// needs to select a row until a right click released it. The row's menu moves the session too.
struct SessionSidebar: View {
  @Bindable var model: AppModel
  /// Focus Sidebar, ⌥⌘1, gives the list the keyboard.
  @FocusState private var isListFocused: Bool
  @State private var swipe: SessionSwipe?
  /// The rows whose selection is drawn by the row itself, from the start of a swipe to the end of
  /// the animation that brings the row back.
  @State private var slidingSessionIDs: Set<SessionID> = []
  /// The row under the pointer, for when no row is drawn under the fingers.
  @State private var hoveredSessionID: SessionID?
  /// The group whose header is being dragged, and the one it is over (#44).
  @State private var draggedGroup: SessionFolderKey?
  @State private var targetedGroup: SessionFolderKey?
  /// A drag over a row: taken or refused (#42).
  @State private var rowDropHover: [SessionID: DropHover] = [:]
  @State private var springLoading = SpringLoading()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      ColumnTabs(model: model)
      columns
      Divider()
      ArchivedSessionsBar(model: model)
      Divider()
      SidebarFooter(model: model)
    }
    .searchable(
      text: Binding(get: { model.filter.searchText }, set: { model.setSearchText($0) }),
      placement: .sidebar,
      prompt: Text("Search sessions", bundle: .module)
    )
    .onChange(of: model.filter.column) { closeSwipe(animated: false) }
    // A row left outlined, or about to open, by a drag its delegate never saw end.
    .clearsWhenDragEnds(!rowDropHover.isEmpty) {
      rowDropHover = [:]
      springLoading.cancel()
    }
    // Rows that move under a still pointer do not say so: the hover is only trusted again once
    // the pointer moves.
    .onChange(of: model.visibleSessions.map(\.id)) { hoveredSessionID = nil }
    .onChange(of: model.selectedSessionID) { _, id in
      if swipe != nil, swipe?.sessionID != id { closeSwipe(animated: true) }
    }
  }

  /// Only a click counts: Return also reaches the list's primary action.
  static func isDoubleClick(_ event: NSEvent?) -> Bool {
    guard let event, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
    return event.clickCount == 2
  }

  /// `nil` when there is nothing to undo: ⌘Z then reaches the window, as it did before.
  private var identityUndo: (() -> Void)? {
    guard model.canUndoIdentityChange else { return nil }
    return { Task { await model.undoIdentityChange() } }
  }

  private var identityRedo: (() -> Void)? {
    guard model.canRedoIdentityChange else { return nil }
    return { Task { await model.redoIdentityChange() } }
  }

  /// The list is moving its selection for a key typed in it — an arrow, Home, a letter — rather
  /// than for a click. A shortcut with ⌘, ⌥ or ⌃ goes through the menus, not the list.
  @MainActor private static var isBrowsingKeyPress: Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
    return event.modifierFlags.intersection([.command, .option, .control]).isEmpty
  }

  // MARK: - Columns

  private var columns: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      list(width: width)
        // Its width alone: a height set here would keep the inset below from shortening it, and
        // push the palette out of the column, over the line of the archived sessions.
        .frame(width: width)
        .background(
          HorizontalSwipeMonitor(
            began: { id in beginTrackpadSwipe(on: id, width: width) },
            changed: { delta in swipe?.translation += delta },
            ended: { settleSwipe() },
            // A click on the open row puts its buttons away, as a click anywhere else does. With
            // Reduce Motion the row stays under its buttons, and only they answer.
            clicked: { id in
              if !reduceMotion, id != nil, id == swipe?.sessionID { closeSwipe(animated: true) }
            },
            interrupted: { closeSwipe(animated: true) }
          )
        )
        // Over the foot of the list, never over the session on screen, and the list's last rows
        // stay reachable above it (#40).
        .safeAreaInset(edge: .bottom, spacing: 0) {
          RequestPalette(model: model, maxHeight: geometry.size.height * 0.6)
        }
    }
  }

  private func list(width: CGFloat) -> some View {
    // Only the rows a shortcut can reach claim one, numbered in the order they are drawn.
    let positions = Dictionary(
      uniqueKeysWithValues: model.displayedSessions.prefix(AppModel.shortcutPositionLimit)
        .enumerated().map { ($0.element.id, $0.offset + 1) })
    // A set: ⌘-click, ⇧-click and ⌘A select several sessions (#77). The one on screen stays one.
    return List(
      selection: Binding(
        get: { model.selectedSessionIDs },
        set: { model.selectFromList($0, byKeyboard: isListFocused && Self.isBrowsingKeyPress) })
    ) {
      // The new session's draft (#177), above everything: it is not a session yet, and the one
      // way back to it once the user went elsewhere.
      ForEach(model.newSessionDrafts, id: \.draftID) { draft in
        NewSessionDraftRow(
          draft: draft,
          isShown: model.isPresentingNewSession && draft === model.newSessionModel,
          show: { model.showNewSessionDraft(draft) })
      }
      // At the top, where the user looks after pressing Create, whatever the order below.
      if let creation = model.creationRow {
        SessionCreationRow(creation: creation)
      }
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
            groupHeader(group)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    // No implicit animation on the list: linked against the macOS 15 SDK, the table it stands on
    // left rows of an animated update behind, drawn over the others and deaf to clicks. The
    // table animates its own insertions and removals.
    // The menu of the rows clicked: the whole selection when the click is in it, the row alone
    // otherwise, as in the Finder (#77). A group's header keeps its own.
    .contextMenu(forSelectionType: SessionID.self) { ids in
      SessionSelectionMenu(model: model, ids: ids)
    } primaryAction: { ids in
      // A double-click renames the row (#183). Return comes here too, and is left to the key
      // handler below, which hands the keyboard to the session.
      guard Self.isDoubleClick(NSApp.currentEvent), ids.count == 1, let id = ids.first else {
        return
      }
      model.beginRename(id, in: .sidebar)
    }
    .focused($isListFocused)
    // ⌘Z and ⇧⌘Z undo a rename or a change of icon while the keyboard is in the list (#183);
    // anywhere else, they go on to what holds it. A field being edited keeps its own.
    .onCommand(Selector(("undo:")), perform: identityUndo)
    .onCommand(Selector(("redo:")), perform: identityRedo)
    .onChange(of: model.sidebarFocusRequest) { isListFocused = true }
    // The keyboard gone elsewhere, ⇧⌘W and the Session menu act on the session on screen alone:
    // a selection nobody is looking at must not be what a shortcut typed in a terminal closes.
    // Told by the window rather than by `isListFocused`, which a click in the terminal left true
    // (#128). The search field counts as the sidebar: a search prunes the selection, it does not
    // shrink it. A menu — the list's own, or the Session menu — does not move the keyboard: the
    // selection holds until its command.
    .background(KeyboardDepartureMonitor { model.collapseSelection() })
    // Walked with the arrows, the list keeps the keyboard (#105); Return or → hands it to the
    // session on the row. A session that cannot take it — its agent stopped — leaves it here.
    .onKeyPress(keys: [.return, .rightArrow], phases: .down) { press in
      guard press.modifiers.isEmpty, !model.hasMultipleSelection, model.selectedSessionID != nil
      else { return .ignored }
      return model.focusSession() ? .handled : .ignored
    }
    .onKeyPress(.escape) {
      if swipe != nil {
        closeSwipe(animated: true)
        return .handled
      }
      guard model.hasMultipleSelection else { return .ignored }
      model.collapseSelection()
      return .handled
    }
    .accessibilityLabel(Text("Sessions", bundle: .module))
    .accessibilityIdentifier("session-list")
    .alert(
      Text("The session could not be changed.", bundle: .module),
      isPresented: Binding(
        get: { model.identityFailure != nil },
        set: { if !$0 { model.dismissIdentityFailure() } })
    ) {
      Button(LocalizedStringResource("OK", bundle: .module)) { model.dismissIdentityFailure() }
    } message: {
      Text(verbatim: model.identityFailure ?? "")
    }
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
      if model.visibleSessions.isEmpty, model.creationRow == nil, model.newSessionDrafts.isEmpty {
        emptyState
      }
    }
  }

  /// A row is dragged among the rows of its own `ForEach`: its column, or its group. The list
  /// draws no insertion point in another group, which is how a drop there is refused (#44).
  private func rows(
    _ sessions: [WorkSession], positions: [SessionID: Int], width: CGFloat
  ) -> some View {
    ForEach(sessions) { session in
      row(for: session, position: positions[session.id], width: width)
        .tag(session.id)
    }
    .onMove(perform: model.canReorder ? { move(sessions, from: $0, to: $1) } : nil)
  }

  /// `destination` counts the rows before the move; the model counts them without the one moved.
  private func move(_ sessions: [WorkSession], from source: IndexSet, to destination: Int) {
    guard let first = source.first, sessions.indices.contains(first) else { return }
    closeSwipe(animated: false)
    let id = sessions[first].id
    let index = destination > first ? destination - 1 : destination
    Task { await model.move(id, toIndex: index) }
  }

  // MARK: - Groups

  /// A header is dragged onto another one to move its whole group there. The list cannot move
  /// sections itself, so the header carries the drag: its folder's path, which is what a header
  /// dropped anywhere else in the system would mean.
  @ViewBuilder
  private func groupHeader(_ group: SessionGroup) -> some View {
    // Not `draggedGroup`: a header dropped out of the window leaves it behind.
    let canMove = group.id != nil && model.canReorder
    let header = SessionGroupHeader(
      model: model, group: group, isDragging: targetedGroup != nil,
      startDrag: canMove ? { startDragging(group) } : nil
    )
    .overlay(alignment: .top) {
      if let folder = group.id, targetedGroup == folder, let draggedGroup,
        draggedGroup != folder
      {
        Rectangle()
          .fill(Color.accentColor)
          .frame(height: 2)
          .accessibilityHidden(true)
      }
    }
    if let folder = group.id, canMove {
      header
        .onDrop(
          of: [.text],
          delegate: GroupDropDelegate(
            target: folder,
            dragged: $draggedGroup,
            targeted: $targetedGroup,
            drop: { [model] dragged in Self.dropGroup(dragged, on: folder, model: model) }
          )
        )
    } else {
      header
    }
  }

  private func startDragging(_ group: SessionGroup) -> NSItemProvider {
    guard let folder = group.id else { return NSItemProvider() }
    closeSwipe(animated: false)
    draggedGroup = folder
    return NSItemProvider(object: folder.path as NSString)
  }

  /// The group dropped takes the place of the one it was dropped on: above it when it came from
  /// below, under it when it came from above.
  private static func dropGroup(
    _ dragged: SessionFolderKey, on target: SessionFolderKey, model: AppModel
  ) {
    let groups = model.groups
    guard dragged != target, let group = groups.first(where: { $0.id == dragged }),
      let index = groups.filter({ $0.id != nil }).firstIndex(where: { $0.id == target })
    else { return }
    Task { await model.moveGroup(group, toIndex: index) }
  }

  private func row(for session: WorkSession, position: Int?, width: CGFloat) -> some View {
    let isSwiped = swipe?.sessionID == session.id
    let rowOffset = isSwiped && !reduceMotion ? swipe?.offset ?? 0 : 0
    let commands = SessionCommands(model: model, session: session)
    let appearance = model.displayedAppearance(of: session)
    return SessionRow(
      session: session,
      appearance: appearance,
      icon: model.icons.image(for: appearance.iconID),
      status: model.statusPresentation(for: session),
      isRestoring: model.isRestoring(session.id),
      webView: model.webViewAttention(for: session.id),
      shortcutPosition: position,
      commands: commands
    )
    // Moves with the row: a click on the buttons a swipe uncovered is not a click on the row. It
    // carries the row's selection too, which the list draws out of SwiftUI's reach.
    .background(
      SwipeRowMarker(
        sessionID: session.id,
        carriesSelection: !reduceMotion && slidingSessionIDs.contains(session.id))
    )
    // Only the swiped row moves, out of the way of its buttons. With Reduce Motion it stays,
    // and the buttons fade in over it.
    .offset(x: rowOffset)
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
    // A row of a selection of several also reaches the commands on the whole selection, the
    // way its menu does, for VoiceOver (#77).
    .accessibilityActions {
      if model.hasMultipleSelection, model.selectedSessionIDs.contains(session.id) {
        SessionBatchCommandButtons(model: model, ids: model.commandTargets, includesStatus: false)
      }
    }
    .onHover { isHovering in
      if isHovering {
        hoveredSessionID = session.id
      } else if hoveredSessionID == session.id {
        hoveredSessionID = nil
      }
    }
    // A drop, not a gesture: the row keeps its click (#96).
    .overlay {
      if let hover = rowDropHover[session.id] {
        RoundedRectangle(cornerRadius: 6)
          .stroke(hover.isRefusing ? Color.red : Color.accentColor, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .onDrop(
      of: DropReader.acceptedTypes,
      delegate: SessionRowDropDelegate(
        model: model, sessionID: session.id, springLoading: springLoading,
        hovered: Binding(
          get: { rowDropHover[session.id] },
          set: { rowDropHover[session.id] = $0 })))
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

  /// - Parameter id: the session of the row drawn under the fingers. The hover is only asked when
  ///   the monitor found none.
  private func beginTrackpadSwipe(on id: SessionID?, width: CGFloat) -> Bool {
    let visible = model.visibleSessions
    guard let session = (id ?? hoveredSessionID).flatMap({ id in visible.first { $0.id == id } })
    else { return false }
    // A swipe on the row already open takes it from where it is.
    if swipe?.sessionID != session.id {
      swipe = makeSwipe(for: session, width: width)
      slidingSessionIDs.insert(session.id)
    }
    return true
  }

  private func settleSwipe() {
    guard let current = swipe else { return }
    let settled = current.settledTranslation
    animateSwipe(reduceMotion ? nil : .snappy) {
      if settled == 0 {
        swipe = nil
      } else {
        swipe?.translation = settled
      }
    }
  }

  private func closeSwipe(animated: Bool) {
    guard swipe != nil else { return }
    animateSwipe(animated && !reduceMotion ? .snappy : nil) { swipe = nil }
  }

  /// A row put back gives its selection back to the list once it is home, not before.
  private func animateSwipe(_ animation: Animation?, _ change: () -> Void) {
    let putBack = {
      slidingSessionIDs = slidingSessionIDs.filter { $0 == swipe?.sessionID }
    }
    guard let animation else {
      change()
      return putBack()
    }
    withAnimation(animation, completionCriteria: .logicallyComplete, change, completion: putBack)
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

// MARK: - Group drop

/// Takes only a header of this list: text dragged in from elsewhere is not a group.
private struct GroupDropDelegate: DropDelegate {
  let target: SessionFolderKey
  @Binding var dragged: SessionFolderKey?
  @Binding var targeted: SessionFolderKey?
  let drop: @MainActor @Sendable (SessionFolderKey) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    dragged != nil
  }

  func dropEntered(info: DropInfo) {
    guard dragged != nil else { return }
    targeted = target
  }

  func dropExited(info: DropInfo) {
    if targeted == target { targeted = nil }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: dragged == nil || dragged == target ? .forbidden : .move)
  }

  /// A header dragged out of the window and dropped elsewhere never says so, and leaves `dragged`
  /// behind: the text carried is checked, so that a path dropped later from another application
  /// is not taken for that old drag.
  func performDrop(info: DropInfo) -> Bool {
    let moved = dragged
    dragged = nil
    targeted = nil
    guard let moved, moved != target,
      let provider = info.itemProviders(for: [.text]).first
    else { return false }
    let drop = drop
    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
      guard let path = object as? String, path == moved.path else { return }
      Task { @MainActor in drop(moved) }
    }
    return true
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
  @Bindable var model: AppModel

  var body: some View {
    Button {
      model.isArchiveListPresented.toggle()
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
    .popover(isPresented: $model.isArchiveListPresented, arrowEdge: .trailing) {
      ArchivedSessionsList(model: model)
    }
    // After the line is laid out, not as it appears: the popover needs its anchor on screen.
    .task { model.presentPendingArchiveList() }
  }
}

private struct ArchivedSessionsList: View {
  let model: AppModel
  /// Several archived sessions can be unarchived at once (#77). A click on one alone shows it.
  @State private var selection: Set<SessionID> = []

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
        VStack(spacing: 0) {
          // No gesture on the rows: it would keep the clicks the list needs to select (#96).
          List(archived, selection: $selection) { session in
            HStack(spacing: 8) {
              SessionBadge(
                appearance: session.appearance,
                icon: model.icons.image(for: session.appearance.iconID))
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
            .accessibilityAction(named: Text("Show", bundle: .module)) {
              model.showArchived(session.id)
            }
          }
          .listStyle(.plain)
          .contextMenu(forSelectionType: SessionID.self) { ids in
            let plan = model.batchPlan(.unarchive, for: ordered(ids, in: archived))
            if ids.count > 1, !plan.isEmpty {
              Button(model.batchTitle(for: plan)) { Task { await model.requestBatch(plan) } }
            } else if let id = ids.first {
              // Shown in the main area, and edited in the inspector's header (#183).
              Button(
                LocalizedStringResource("Rename", bundle: .module, comment: "Renames a session.")
              ) {
                editArchived(id) { model.beginRename(id, in: .inspector) }
              }
              Button(LocalizedStringResource("Change Icon…", bundle: .module)) {
                editArchived(id) { model.beginAppearanceEditing(id, in: .inspector) }
              }
              Divider()
              Button(LocalizedStringResource("Unarchive", bundle: .module)) {
                Task { await model.restore(id) }
              }
            }
          }
          .onChange(of: selection) { _, ids in
            if ids.count == 1, let id = ids.first { model.showArchived(id) }
          }
          let plan = model.batchPlan(.unarchive, for: ordered(selection, in: archived))
          if selection.count > 1, !plan.isEmpty {
            Divider()
            HStack {
              Spacer()
              Button(model.batchTitle(for: plan)) {
                Task { await model.requestBatch(plan) }
                selection = []
              }
              .controlSize(.small)
              .accessibilityIdentifier("unarchive-selection")
            }
            .padding(8)
          }
        }
      }
    }
    .frame(width: 320, height: 300)
  }

  /// The list's popover closes first: a second popover does not open over it.
  private func editArchived(_ id: SessionID, _ edit: @escaping () -> Void) {
    model.showArchived(id)
    model.isArchiveListPresented = false
    Task { @MainActor in edit() }
  }

  private func ordered(_ ids: Set<SessionID>, in archived: [WorkSession]) -> [SessionID] {
    archived.map(\.id).filter { ids.contains($0) }
  }
}
