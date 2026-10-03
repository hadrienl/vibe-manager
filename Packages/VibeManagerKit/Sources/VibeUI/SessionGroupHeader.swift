import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// The header of a group of the sidebar: its folder, how many sessions it holds and the most
/// pressing of their states — all readable with the group folded (#27).
struct SessionGroupHeader: View {
  let model: AppModel
  let group: SessionGroup
  /// A header is being dragged over the list: its + stays hidden (#106).
  var isDragging = false
  /// What the header carries when it is dragged to move its group; `nil` when it cannot move.
  var startDrag: (() -> NSItemProvider)? = nil
  @State private var isRenaming = false
  @State private var isHovering = false
  @State private var name = ""
  @FocusState private var isNameFocused: Bool

  var body: some View {
    if let startDrag {
      // A drag takes the pointer without a hover ending: the + would stay, in the drag's image
      // and on the header once dropped.
      header.onDrag {
        isHovering = false
        return startDrag()
      }
    } else {
      header
    }
  }

  @ViewBuilder
  private var header: some View {
    let summary = model.summary(of: group)
    let isExpanded = model.isExpanded(group)
    let containsSelection =
      !isExpanded && group.sessions.contains { $0.id == model.selectedSessionID }
    let newSession = model.newSessionAvailability(in: group, isRenaming: isRenaming)
    HStack(spacing: 6) {
      badge
      if isRenaming {
        TextField(text: $name) {
          Text("Group name", bundle: .module, comment: "The field that renames a group.")
        }
        .textFieldStyle(.roundedBorder)
        .focused($isNameFocused)
        // Once the field exists: asked for in the update that inserts it, the focus is dropped.
        .task { isNameFocused = true }
        .onSubmit(commitRename)
        .onExitCommand { isRenaming = false }
        .onChange(of: isNameFocused) { _, isFocused in
          if !isFocused, isRenaming { commitRename() }
        }
      } else {
        title
          .foregroundStyle(containsSelection ? Color.accentColor : Color.primary)
      }
      if group.isMissing {
        Image(systemName: "questionmark.folder")
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      countOrNewSession(newSession)
      if let headline = summary.headline {
        Image(systemName: headline.symbolName)
          .foregroundStyle(headline.severity.tint)
          .help(Text(headline.label))
      }
    }
    .font(.subheadline.weight(.semibold))
    .lineLimit(1)
    .help(helpText)
    .onHover { isHovering = $0 }
    .contextMenu { menu(isExpanded: isExpanded) }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("session-group-header")
    .accessibilityLabel(
      SessionGroupStatus.accessibilityLabel(
        for: group, summary: summary, isExpanded: isExpanded,
        containsSelection: containsSelection)
    )
    .accessibilityAction(
      named: isExpanded
        ? Text("Collapse", bundle: .module, comment: "Folds a group of the sidebar.")
        : Text("Expand", bundle: .module, comment: "Unfolds a group of the sidebar.")
    ) {
      model.setExpanded(!isExpanded, group: group)
    }
    .accessibilityAction(named: Text("Rename", bundle: .module, comment: "Renames a group.")) {
      beginRename()
    }
    // Dragging the header, without the drag (#44).
    .accessibilityActions {
      if newSession.isEnabled {
        Button {
          model.beginNewSession(in: group)
        } label: {
          Text("New Session in This Folder", bundle: .module)
        }
      }
      if model.canMoveGroup(group, by: -1) {
        Button {
          Task { await model.moveGroup(group, by: -1) }
        } label: {
          Text("Move Group Up", bundle: .module)
        }
      }
      if model.canMoveGroup(group, by: 1) {
        Button {
          Task { await model.moveGroup(group, by: 1) }
        } label: {
          Text("Move Group Down", bundle: .module)
        }
      }
    }
  }

  /// The + takes the count's place on hover, in a slot as wide as the wider of the two, so that
  /// neither the title nor the state moves when it shows (#106).
  private func countOrNewSession(_ newSession: GroupNewSession) -> some View {
    let showsButton = isHovering && !isDragging && newSession.isShown
    return ZStack(alignment: .trailing) {
      Text(verbatim: "\(group.sessions.count)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .opacity(showsButton ? 0 : 1)
      if group.id != nil {
        newSessionButton(newSession)
          .opacity(showsButton ? 1 : 0)
          .allowsHitTesting(showsButton)
      }
    }
  }

  /// Never `.disabled`: the help tag of a disabled control does not show, and it is what says why
  /// nothing happens. VoiceOver has the header's action instead.
  private func newSessionButton(_ newSession: GroupNewSession) -> some View {
    Button {
      model.beginNewSession(in: group)
    } label: {
      // On the image: a borderless button tints its label with its own style.
      Image(systemName: "plus")
        .foregroundStyle(
          newSession.isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
        )
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(newSessionHelp(newSession))
    .accessibilityHidden(true)
  }

  private func newSessionHelp(_ newSession: GroupNewSession) -> Text {
    switch newSession {
    case .disabled(.folderMissing):
      return Text(
        "Folder not found: \(group.displayPath)", bundle: .module,
        comment: "The help tag of the + of a group whose folder was moved or deleted.")
    case .disabled(.creationUnavailable):
      return Text(
        "No agent available to create a session", bundle: .module,
        comment: "The help tag of the + of a group when no session can be created.")
    case .hidden, .enabled:
      return Text(
        "New Session in “\(group.title)”\n\(group.displayPath)", bundle: .module,
        comment: "The help tag of the + of a group: its name, then its folder's path.")
    }
  }

  @ViewBuilder
  private var badge: some View {
    // The icon of the first session that has one, so the group wears its project's icon.
    if let appearance = group.sessions.lazy.map(model.displayedAppearance(of:))
      .first(where: { $0.iconID != nil }),
      let icon = model.icons.image(for: appearance.iconID)
    {
      SessionBadge(appearance: appearance, icon: icon, size: 16)
    } else {
      Image(systemName: group.id == nil ? "tray" : "folder")
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
  }

  @ViewBuilder
  private var title: some View {
    if group.id == nil {
      Text(
        "No Folder", bundle: .module,
        comment: "The group of the sessions that have no working folder.")
    } else {
      Text(verbatim: group.title)
    }
  }

  private var helpText: Text {
    guard group.id != nil else {
      return Text(
        "No Folder", bundle: .module,
        comment: "The group of the sessions that have no working folder.")
    }
    guard group.isMissing else { return Text(verbatim: group.displayPath) }
    return Text(
      "\(group.displayPath) — Folder not found", bundle: .module,
      comment: "The help tag of a group whose working folder was moved or deleted.")
  }

  @ViewBuilder
  private func menu(isExpanded: Bool) -> some View {
    if group.id != nil {
      Button(LocalizedStringResource("New Session in This Folder", bundle: .module)) {
        model.beginNewSession(in: group)
      }
      .disabled(!model.newSessionAvailability(in: group).isEnabled)
      Divider()
      Button(LocalizedStringResource("Rename Group…", bundle: .module)) { beginRename() }
      if group.isRenamed {
        Button(LocalizedStringResource("Use Folder Name", bundle: .module)) {
          Task { await model.rename(group, to: "") }
        }
      }
    }
    Button(
      isExpanded
        ? LocalizedStringResource("Collapse Group", bundle: .module)
        : LocalizedStringResource("Expand Group", bundle: .module)
    ) {
      model.setExpanded(!isExpanded, group: group)
    }
    .disabled(!model.canFold)
    if group.id != nil, model.canReorder {
      Divider()
      Button(LocalizedStringResource("Move Group Up", bundle: .module)) {
        Task { await model.moveGroup(group, by: -1) }
      }
      .disabled(!model.canMoveGroup(group, by: -1))
      Button(LocalizedStringResource("Move Group Down", bundle: .module)) {
        Task { await model.moveGroup(group, by: 1) }
      }
      .disabled(!model.canMoveGroup(group, by: 1))
    }
    if let folder = group.id {
      Divider()
      Button(LocalizedStringResource("Reveal in Finder", bundle: .module)) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
      }
      .disabled(group.isMissing)
    }
  }

  private func beginRename() {
    guard group.id != nil else { return }
    name = group.title
    isRenaming = true
    isNameFocused = true
  }

  /// Return keeps the name; a name left empty gives the group back its folder's.
  private func commitRename() {
    guard isRenaming else { return }
    isRenaming = false
    let name = name
    guard FolderLabel.normalized(name) != group.customName else { return }
    Task { await model.rename(group, to: name == group.folderName ? "" : name) }
  }
}
