import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// Settings › Requests › Avatars (#154): the library on the layout of Settings › Conversation —
/// the avatars in a list, the one selected in a preview beside it.
///
/// The list holds the default avatar first, those kept, the drafts still to check, the generation
/// under way and those that failed, then the card that makes a new one. Selecting only shows an
/// avatar: "Use This Avatar" alone changes the one of the floating panel.
struct AvatarLibraryView: View {
  @Bindable var avatars: AvatarLibraryModel
  /// Whether the card that makes a new avatar is unfolded. Not kept: the page opens with it folded.
  @State var isCreating: Bool
  @State var isDropTargeted = false
  @State var isChoosingArchive = false
  @State var isExporting = false
  @State var exportDocument: AvatarArchiveDocument?
  @State var exportName = ""
  /// The avatar being renamed, and the name typed.
  @State var renaming: AvatarID?
  @State var newName = ""
  /// The avatar whose deletion waits for its confirmation.
  @State var deleting: AvatarID?
  @FocusState var isDescriptionFocused: Bool
  @Environment(\.locale) var locale

  /// The width of the list, as the form of Settings › Conversation.
  static let listWidth: CGFloat = 520
  /// The width of the preview: the rest of the page, less the divider.
  static let previewWidth: CGFloat = 379
  /// What identifies the card in the list, to scroll to it.
  static let cardID = "new-avatar-card"

  init(avatars: AvatarLibraryModel, isCreating: Bool = false) {
    self.avatars = avatars
    _isCreating = State(initialValue: isCreating)
  }

  var body: some View {
    HStack(spacing: 0) {
      library
        .frame(width: Self.listWidth)
      Divider()
      preview
        .frame(width: Self.previewWidth)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // The library is read again by the tab, once each time it appears; the agents, here.
    .task { await avatars.refreshOptions() }
    .fileImporter(isPresented: $isChoosingArchive, allowedContentTypes: [.zip]) { result in
      guard case .success(let url) = result else { return }
      importArchive(at: url)
    }
    .fileExporter(
      isPresented: $isExporting, document: exportDocument, contentType: .zip,
      defaultFilename: exportName
    ) { _ in
      exportDocument = nil
    }
    .alert(
      Text("Rename the Avatar", bundle: .module),
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField(text: $newName) {
        Text("Name", bundle: .module)
      }
      Button {
        if let id = renaming {
          let name = newName
          Task { await avatars.rename(id, to: name) }
        }
        renaming = nil
      } label: {
        Text("Rename", bundle: .module)
      }
      .disabled(AvatarLibraryRules.name(newName) == nil)
      Button(role: .cancel) {
        renaming = nil
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: {
      Text("\(AvatarManifest.maximumNameLength) characters at most.", bundle: .module)
    }
    .confirmationDialog(
      deletionTitle,
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { id in
      Button(role: .destructive) {
        Task { await avatars.remove(id) }
        deleting = nil
      } label: {
        if avatars.entry(id)?.isDraft == true {
          Text("Discard", bundle: .module)
        } else {
          Text("Delete", bundle: .module)
        }
      }
      Button(role: .cancel) {
        deleting = nil
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: { id in
      deletionMessage(id)
    }
  }

  // MARK: - The list

  private var library: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Avatars", bundle: .module).font(.headline)
        Spacer()
        Text(
          AvatarLibraryPresentation.summary(
            count: avatars.entries.count,
            byteCount: avatars.entries.reduce(0) { $0 + $1.byteCount }, locale: locale)
        )
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("avatar-library-summary")
      }
      ScrollViewReader { proxy in
        List(selection: selection) {
          ForEach(avatars.entries) { entry in
            AvatarRow(
              avatars: avatars, entry: entry, isSelected: avatars.selection == .avatar(entry.id),
              menu: { menuItems(for: entry) }
            )
            .tag(AvatarLibraryModel.Selection.avatar(entry.id))
            .contextMenu { menuItems(for: entry, showsShortcut: true) }
          }
          // The list's table is drawn above the page's own drop destination, not inside it: an
          // archive dropped between its rows reaches the page through here.
          .onInsert(of: [.fileURL]) { _, providers in
            dropFiles(providers)
          }
          ForEach(AvatarLibraryPresentation.listedJobs(avatars.jobs)) { job in
            AvatarJobRow(avatars: avatars, job: job)
              .tag(AvatarLibraryModel.Selection.job(job.id))
          }
          if avatars.isImporting {
            AvatarImportRow()
              .selectionDisabled()
          }
          NewAvatarCard(
            avatars: avatars, isExpanded: $isCreating,
            isDescriptionFocused: $isDescriptionFocused,
            chooseArchive: { isChoosingArchive = true },
            generate: {
              avatars.generate()
              isCreating = false
            }
          )
          .selectionDisabled()
          .id(Self.cardID)
        }
        .listStyle(.inset)
        .onChange(of: isCreating) { _, isCreating in
          guard isCreating else { return }
          withAnimation { proxy.scrollTo(Self.cardID, anchor: .bottom) }
          isDescriptionFocused = true
        }
        // What was just made, or started, comes into view.
        .onChange(of: avatars.selection) { _, selection in
          guard let selection else { return }
          proxy.scrollTo(selection)
        }
        .onKeyPress(.return) {
          guard let id = avatars.selectedID, avatars.canRename(id) else { return .ignored }
          startRenaming(id)
          return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
          guard press.modifiers.contains(.command), let id = avatars.selectedID, id != .default
          else { return .ignored }
          deleting = id
          return .handled
        }
      }
      .accessibilityIdentifier("avatar-library-list")
      Text(
        "A zip archive dropped on the list is imported: one image per expression (neutral.png, pleased.png…).",
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 20))
    .dropDestination(for: URL.self) { urls, _ in
      drop(urls)
    } isTargeted: {
      isDropTargeted = $0
    }
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0)
        .padding(6)
        .allowsHitTesting(false))
  }

  /// What the list selects: the model's, changed at once.
  private var selection: Binding<AvatarLibraryModel.Selection?> {
    Binding(get: { avatars.selection }, set: { avatars.choose($0) })
  }

  // MARK: - Actions

  /// The actions of an avatar: in the menus ••• of its row and of the preview, and in its
  /// contextual menu, which alone shows ⌘⌫ — the list takes it as well.
  @ViewBuilder
  func menuItems(for entry: AvatarLibraryEntry, showsShortcut: Bool = false) -> some View {
    let actions = AvatarLibraryPresentation.actions(
      for: entry, inUse: avatars.inUse, canCreate: avatars.canCreate,
      canRename: avatars.canRename(entry.id))
    if actions.contains(.use) {
      Button {
        Task { await avatars.use(entry.id) }
      } label: {
        Text("Use This Avatar", bundle: .module)
      }
      .disabled(!actions.enabled(.use))
    }
    if actions.contains(.rename) {
      Button {
        startRenaming(entry.id)
      } label: {
        Text("Rename…", bundle: .module)
      }
      .disabled(!actions.enabled(.rename))
    }
    if actions.contains(.duplicate) {
      Button {
        Task { await avatars.duplicate(entry.id) }
      } label: {
        Text("Duplicate", bundle: .module)
      }
      .disabled(!actions.enabled(.duplicate))
    }
    if actions.contains(.export) {
      Divider()
      Button {
        export(entry.id, includingDescription: true)
      } label: {
        Text("Export…", bundle: .module)
      }
      .disabled(!actions.enabled(.export))
      Button {
        export(entry.id, includingDescription: false)
      } label: {
        Text("Export Without the Description…", bundle: .module)
      }
      .disabled(!actions.enabled(.export))
    }
    if actions.contains(.delete) {
      Divider()
      Button(role: .destructive) {
        deleting = entry.id
      } label: {
        if entry.isDraft {
          Text("Discard…", bundle: .module)
        } else {
          Text("Delete…", bundle: .module)
        }
      }
      // Only in the contextual menu, built when it opens: the menus ••• stay on the page, and
      // would take ⌘⌫ from the description being typed.
      .keyboardShortcut(showsShortcut ? KeyboardShortcut(.delete, modifiers: .command) : nil)
    }
  }

  func startRenaming(_ id: AvatarID) {
    guard avatars.canRename(id), let entry = avatars.entry(id) else { return }
    newName = AvatarLibraryModel.name(of: entry)
    renaming = id
  }

  private var deletionTitle: Text {
    guard let id = deleting, let entry = avatars.entry(id) else { return Text(verbatim: "") }
    let name = DisplaySafeText.visible(AvatarLibraryModel.name(of: entry))
    return entry.isDraft
      ? Text("Discard “\(name)”?", bundle: .module)
      : Text("Delete “\(name)”?", bundle: .module)
  }

  private func deletionMessage(_ id: AvatarID) -> Text {
    if avatars.entry(id)?.isDraft == true {
      return Text("What was drawn is lost.", bundle: .module)
    }
    if id == avatars.inUse {
      return Text(
        "The floating panel will go back to the default avatar. Export it first to keep it.",
        bundle: .module)
    }
    return Text("It cannot be recovered. Export it first to keep it.", bundle: .module)
  }

  func export(_ id: AvatarID, includingDescription: Bool) {
    Task {
      guard let data = await avatars.exportArchive(id, includingDescription: includingDescription)
      else { return }
      exportName = avatars.exportFileName(id)
      exportDocument = AvatarArchiveDocument(data: data)
      isExporting = true
    }
  }

  // MARK: - Archives

  /// An archive dropped on the list: the first zip file is imported, when something new can be
  /// made now.
  private func drop(_ urls: [URL]) -> Bool {
    guard let url = AvatarLibraryPresentation.archive(in: urls), avatars.isIdle else {
      return false
    }
    importArchive(at: url)
    return true
  }

  /// Files dropped between the rows of the list: their URLs are read, then dropped as on the page.
  private func dropFiles(_ providers: [NSItemProvider]) {
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in _ = drop([url]) }
      }
    }
  }

  func importArchive(at url: URL) {
    guard avatars.canCreate else {
      // Refused unread: the model says that the library is full.
      Task { await avatars.importArchive(Data()) }
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    // Read with the same bound as the archive itself: a larger file is not read at all.
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
      avatars.reject(.archiveUnreadable)
      return
    }
    guard size <= 30 * 1024 * 1024 else {
      avatars.reject(.archiveTooLarge)
      return
    }
    guard let data = try? Data(contentsOf: url) else {
      avatars.reject(.archiveUnreadable)
      return
    }
    Task {
      await avatars.importArchive(data)
      // Imported: the card folds up, its work done.
      if avatars.problem == nil { isCreating = false }
    }
  }
}

// MARK: - Rows

/// A pill beside an avatar's name: never a colour alone, always words and a symbol.
struct AvatarBadge: View {
  enum Kind {
    case inUse, toCheck, running, failed, unreadable, incomplete
  }

  let kind: Kind

  var body: some View {
    Label {
      label
    } icon: {
      Image(systemName: symbol)
    }
    .labelStyle(.titleAndIcon)
    .font(.caption.weight(.semibold))
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .foregroundStyle(tint)
    .background(Capsule().fill(tint.opacity(0.15)))
  }

  private var label: Text {
    switch kind {
    case .inUse: Text("In Use", bundle: .module, comment: "The avatar of the floating panel.")
    case .toCheck:
      Text("To Check", bundle: .module, comment: "An avatar made and not yet kept.")
    case .running: Text("Under Way", bundle: .module, comment: "An avatar being drawn.")
    case .failed: Text("Failed", bundle: .module, comment: "An avatar that could not be drawn.")
    case .unreadable:
      Text("Unreadable", bundle: .module, comment: "An avatar that cannot be read.")
    case .incomplete:
      Text("Incomplete", bundle: .module, comment: "An avatar that lacks expressions.")
    }
  }

  private var symbol: String {
    switch kind {
    case .inUse: "checkmark"
    case .toCheck: "questionmark.circle"
    case .running: "hourglass"
    case .failed, .unreadable: "exclamationmark.triangle"
    case .incomplete: "square.dashed"
    }
  }

  private var tint: Color {
    switch kind {
    case .inUse, .running: .accentColor
    case .toCheck, .incomplete: .orange
    case .failed, .unreadable: .red
    }
  }
}

/// The square an avatar's face, or its state, is shown in.
struct AvatarThumbnail<Content: View>: View {
  var size: CGFloat = 46
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: size * 0.2).fill(.quaternary))
      .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
  }
}

/// An avatar of the library: its face, its name, where it comes from, and its state.
struct AvatarRow<Menu: View>: View {
  let avatars: AvatarLibraryModel
  let entry: AvatarLibraryEntry
  let isSelected: Bool
  @ViewBuilder let menu: () -> Menu
  @Environment(\.locale) private var locale

  var body: some View {
    let name = DisplaySafeText.visible(AvatarLibraryModel.name(of: entry))
    let redrawing = avatars.work.flatMap { $0.avatar == entry.id ? $0 : nil }
    HStack(spacing: 11) {
      AvatarThumbnail {
        if let image = avatars.thumbnails[entry.id] {
          AvatarView(images: [.neutral: image], expression: .neutral, size: 44)
        } else if entry.problem == .unreadable {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        nameText(name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(Text(verbatim: name))
        Group {
          if let redrawing {
            AvatarProgressText(avatars: avatars, job: redrawing)
          } else {
            AvatarLibraryPresentation.origin(of: entry, avatars: avatars, locale: locale)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      if redrawing?.phase == .running {
        Button {
          avatars.cancel()
        } label: {
          Text("Cancel", bundle: .module)
        }
        .controlSize(.small)
      }
      if entry.id == avatars.inUse {
        AvatarBadge(kind: .inUse)
      }
      if entry.isDraft {
        AvatarBadge(kind: .toCheck)
      } else if entry.problem == .unreadable {
        AvatarBadge(kind: .unreadable)
      } else if case .incomplete = entry.problem {
        AvatarBadge(kind: .incomplete)
      }
      if isSelected {
        SwiftUI.Menu {
          menu()
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("More Actions", bundle: .module))
        .accessibilityIdentifier("avatar-row-menu")
      }
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("avatar-row")
  }

  private func nameText(_ name: String) -> Text {
    entry.id == .default ? Text("Default avatar", bundle: .module) : Text(verbatim: name)
  }
}

/// A generation that is not an avatar yet: under way, failed, or not written.
struct AvatarJobRow: View {
  let avatars: AvatarLibraryModel
  let job: AvatarLibraryModel.Job
  @Environment(\.locale) private var locale

  var body: some View {
    HStack(spacing: 11) {
      AvatarThumbnail {
        if job.isUnderWay {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        AvatarLibraryPresentation.name(of: job)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.middle)
        Group {
          switch job.phase {
          case .running, .writing:
            AvatarProgressText(avatars: avatars, job: job)
          case .failed(_, let at):
            Text(
              "Failed · \(at.formatted(AvatarLibraryPresentation.relative(locale)))",
              bundle: .module, comment: "A generation that failed, and when.")
          case .unsaved:
            Text("Not written to disk yet", bundle: .module)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      switch job.phase {
      case .running:
        Button {
          avatars.cancel()
        } label: {
          Text("Cancel", bundle: .module)
        }
        .controlSize(.small)
        .accessibilityIdentifier("avatar-job-cancel")
      case .writing:
        EmptyView()
      case .failed, .unsaved:
        AvatarBadge(kind: .failed)
      }
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("avatar-job-row")
  }
}

/// An archive being read.
struct AvatarImportRow: View {
  var body: some View {
    HStack(spacing: 11) {
      AvatarThumbnail {
        ProgressView().controlSize(.small)
      }
      Text("Reading the archive…", bundle: .module)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.vertical, 4)
  }
}

/// What a generation draws, and for how long it has: "Codex is drawing… 0:42".
struct AvatarProgressText: View {
  let avatars: AvatarLibraryModel
  let job: AvatarLibraryModel.Job

  var body: some View {
    if job.phase == .writing {
      Text("Saving…", bundle: .module, comment: "A generated avatar being written to disk.")
    } else {
      TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
        let elapsed = AvatarLibraryPresentation.elapsed(
          context.date.timeIntervalSince(job.startedAt))
        let agent = AvatarLibraryPresentation.agentName(job.provider.rawValue, avatars: avatars)
        switch job.kind {
        case .wholeSet:
          Text(
            "\(agent) is drawing… \(elapsed)", bundle: .module,
            comment: "While an agent draws an avatar: the agent, then the time since it started.")
        case .expression(let expression):
          Text(
            "\(agent) is drawing “\(Text(AvatarPresentation.name(of: expression)))” again… \(elapsed)",
            bundle: .module,
            comment:
              "While an agent draws one expression again: the agent, the expression, the time since it started."
          )
        }
      }
      .monospacedDigit()
    }
  }
}

// MARK: - The card

/// "Create a New Avatar": the last row of the list. Folded, a dashed line; unfolded, where to
/// describe the avatar, the agent that draws it, and the way to import an archive. Greyed out,
/// with the reason, while something is being made or the library is full.
struct NewAvatarCard: View {
  @Bindable var avatars: AvatarLibraryModel
  @Binding var isExpanded: Bool
  var isDescriptionFocused: FocusState<Bool>.Binding
  let chooseArchive: () -> Void
  let generate: () -> Void

  var body: some View {
    let reason = AvatarLibraryPresentation.creationUnavailability(avatars)
    let isOpen = isExpanded && reason == nil
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 11) {
          Image(systemName: "plus")
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Color.accentColor)
            .frame(width: 46, height: 46)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12)))
          VStack(alignment: .leading, spacing: 1) {
            Text("Create a New Avatar", bundle: .module)
              .fontWeight(.semibold)
              .foregroundStyle(reason == nil ? Color.accentColor : Color.secondary)
            Group {
              if let reason {
                Text(reason)
              } else {
                Text("Describe it to an agent, or import an archive", bundle: .module)
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(reason != nil)
      .accessibilityValue(
        isOpen ? Text("Unfolded", bundle: .module) : Text("Folded", bundle: .module)
      )
      .accessibilityIdentifier("avatar-create-card")
      if isOpen {
        Divider()
        form
          .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 9)
        .fill(isOpen ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.clear))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(
          isOpen ? AnyShapeStyle(.separator) : AnyShapeStyle(.tertiary),
          style: StrokeStyle(lineWidth: isOpen ? 1 : 1.5, dash: isOpen ? [] : [5, 3]))
    )
    .opacity(reason == nil ? 1 : 0.6)
    .padding(.vertical, 6)
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Description", bundle: .module)
          .font(.callout.weight(.medium))
        TextEditor(text: $avatars.description)
          .font(.body)
          .frame(height: 58)
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(RoundedRectangle(cornerRadius: 6).fill(.background))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
          .focused(isDescriptionFocused)
          .accessibilityLabel(Text("Description", bundle: .module))
          .accessibilityIdentifier("avatar-description")
        Text(
          "Its look only: the agent draws the same character in ten expressions.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("Drawn by", bundle: .module)
            .font(.callout.weight(.medium))
          Picker(selection: $avatars.selectedProvider) {
            ForEach(avatars.options) { option in
              Group {
                if let reason = option.unavailability {
                  Text(
                    "\(option.descriptor.displayName) — \(Text(AvatarPresentation.reason(reason)))",
                    bundle: .module,
                    comment: "An agent that cannot draw now, and why.")
                } else {
                  Text(verbatim: option.descriptor.displayName)
                }
              }
              .tag(Optional(option.id))
              .selectionDisabled(option.unavailability != nil)
            }
          } label: {
            Text("Drawn by", bundle: .module)
          }
          .labelsHidden()
          .fixedSize()
          Spacer(minLength: 0)
        }
        Text("The generation uses the account and the quota of this agent.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button {
          chooseArchive()
        } label: {
          Text("Import an Archive…", bundle: .module)
        }
        .accessibilityIdentifier("avatar-import")
        Spacer()
        Button {
          generate()
        } label: {
          Text("Generate", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!avatars.canGenerate)
        .accessibilityIdentifier("avatar-generate")
      }
    }
  }
}

// MARK: - Words

/// What the page of the avatars says, apart from the views: tested without drawing them.
enum AvatarLibraryPresentation {
  /// What can be done to an avatar, and what can be done now.
  struct Actions: Equatable {
    enum Action: CaseIterable {
      case use, rename, duplicate, export, delete
    }

    var offered: [Action]
    var disabled: Set<Action>

    func contains(_ action: Action) -> Bool { offered.contains(action) }
    func enabled(_ action: Action) -> Bool { contains(action) && !disabled.contains(action) }
  }

  /// The actions of an avatar's menu. The default one is used, duplicated and exported; a kept
  /// one also renamed and deleted; a draft only renamed and discarded — it is kept first.
  static func actions(
    for entry: AvatarLibraryEntry, inUse: AvatarID, canCreate: Bool, canRename: Bool
  ) -> Actions {
    var offered: [Actions.Action] = []
    var disabled: Set<Actions.Action> = []
    if !entry.isDraft {
      offered.append(.use)
      if entry.id == inUse || entry.problem != nil { disabled.insert(.use) }
    }
    if entry.id != .default {
      offered.append(.rename)
      if !canRename { disabled.insert(.rename) }
    }
    if !entry.isDraft {
      offered.append(.duplicate)
      if !canCreate || entry.problem != nil { disabled.insert(.duplicate) }
      offered.append(.export)
      if entry.problem == .unreadable { disabled.insert(.export) }
    }
    if entry.id != .default { offered.append(.delete) }
    return Actions(offered: offered, disabled: disabled)
  }

  /// The generations the list shows as rows of their own: a new avatar under way, and those that
  /// failed or were not written. One that redraws an avatar is shown on that avatar's row.
  static func listedJobs(_ jobs: [AvatarLibraryModel.Job]) -> [AvatarLibraryModel.Job] {
    jobs.filter { !($0.isUnderWay && $0.avatar != nil) }
  }

  /// Why no new avatar can be started now; `nil` when one can.
  @MainActor
  static func creationUnavailability(_ avatars: AvatarLibraryModel) -> LocalizedStringResource? {
    if avatars.work != nil {
      return LocalizedStringResource(
        "Available once the generation under way ends", bundle: .module,
        comment: "Why the card that makes an avatar is greyed out.")
    }
    if avatars.isImporting {
      return LocalizedStringResource(
        "Available once the archive is read", bundle: .module,
        comment: "Why the card that makes an avatar is greyed out.")
    }
    if !avatars.canCreate {
      return AvatarPresentation.message(for: .limitReached)
    }
    return nil
  }

  /// "3 avatars · 9.8 MB": the avatars listed, and what they take on disk.
  static func summary(count: Int, byteCount: Int64, locale: Locale) -> LocalizedStringResource {
    let size = byteCount.formatted(.byteCount(style: .file).locale(locale))
    var resource = LocalizedStringResource(
      "\(count) avatars · \(size)", bundle: .module,
      comment: "Above the list of avatars: how many, and their size on disk.")
    resource.locale = locale
    return resource
  }

  /// Where an avatar comes from, and since when: "Drawn by Codex · Sep 26, 2026".
  @MainActor
  static func origin(of entry: AvatarLibraryEntry, avatars: AvatarLibraryModel, locale: Locale)
    -> Text
  {
    if entry.id == .default {
      return Text("Shipped with the application", bundle: .module)
    }
    guard let manifest = entry.manifest else {
      return Text("This avatar cannot be read.", bundle: .module)
    }
    let date = (manifest.createdAt ?? entry.addedAt).formatted(
      .dateTime.day().month(.abbreviated).year().locale(locale))
    switch manifest.source {
    case .generated:
      let agent = agentName(manifest.provider ?? "", avatars: avatars)
      return Text(
        "Drawn by \(agent) · \(date)", bundle: .module,
        comment: "Where an avatar comes from: the agent that drew it, and when.")
    case .imported, .bundled:
      return Text(
        "Imported · \(date)", bundle: .module,
        comment: "Where an avatar comes from: an archive, and when it was made.")
    }
  }

  /// The name an agent is shown under: the one it is registered with, else its identifier.
  @MainActor
  static func agentName(_ provider: String, avatars: AvatarLibraryModel) -> String {
    if let option = avatars.options.first(where: { $0.id.rawValue == provider }) {
      return option.descriptor.displayName
    }
    return provider.isEmpty ? "?" : provider.prefix(1).uppercased() + provider.dropFirst()
  }

  /// What a generation is called before it is an avatar: its description's first line.
  static func name(of job: AvatarLibraryModel.Job) -> Text {
    // Its whole first line: the row cuts it where it must, and says it whole in its tooltip.
    let line = job.description.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
    if let line {
      return Text(verbatim: DisplaySafeText.visible(line))
    }
    return Text("New Avatar", bundle: .module)
  }

  /// "0:42": the time a generation has taken.
  static func elapsed(_ interval: TimeInterval) -> String {
    Duration.seconds(Int(max(interval, 0))).formatted(.time(pattern: .minuteSecond))
  }

  static func relative(_ locale: Locale) -> Date.RelativeFormatStyle {
    Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: locale)
  }

  /// The first zip archive of what was dropped.
  static func archive(in urls: [URL]) -> URL? {
    urls.first { $0.pathExtension.lowercased() == "zip" }
  }
}

/// The archive of an avatar, for the save panel.
struct AvatarArchiveDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.zip]
  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
