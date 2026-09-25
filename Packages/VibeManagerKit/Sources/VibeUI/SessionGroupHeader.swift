import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// The header of a group of the sidebar: its folder, how many sessions it holds and the most
/// pressing of their states — all readable with the group folded (#27).
struct SessionGroupHeader: View {
  let model: AppModel
  let group: SessionGroup
  @State private var isRenaming = false
  @State private var name = ""
  @FocusState private var isNameFocused: Bool

  var body: some View {
    let summary = model.summary(of: group)
    let isExpanded = model.isExpanded(group)
    let containsSelection =
      !isExpanded && group.sessions.contains { $0.id == model.selectedSessionID }
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
      Text(verbatim: "\(group.sessions.count)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
      if let headline = summary.headline {
        Image(systemName: headline.symbolName)
          .foregroundStyle(tint(headline.severity))
          .help(Text(headline.label))
      }
    }
    .font(.subheadline.weight(.semibold))
    .lineLimit(1)
    .help(helpText)
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
  }

  @ViewBuilder
  private var badge: some View {
    // The icon of the first session that has one, so the group wears its project's icon.
    if let appearance = group.sessions.first(where: { $0.appearance.iconID != nil })?.appearance,
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
    if let folder = group.id {
      Button(LocalizedStringResource("New Session in This Folder", bundle: .module)) {
        model.beginNewSession(folder: folder.path)
      }
      .disabled(!model.canCreateSession || group.isMissing)
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

  private func tint(_ severity: SessionStatusSeverity) -> Color {
    switch severity {
    case .normal: return .secondary
    case .active: return .accentColor
    case .attention: return .orange
    case .error: return .red
    }
  }
}

/// The archived sessions of the Closed tab, apart from the groups: they no longer count in them.
struct ArchivedSectionHeader: View {
  let count: Int

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
      Text("Archived Sessions", bundle: .module, comment: "A section of the sidebar.")
      Spacer(minLength: 4)
      Text(verbatim: "\(count)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .font(.subheadline.weight(.semibold))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}
