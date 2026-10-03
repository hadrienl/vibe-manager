import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// A session's drawer of side terminals (#43): a bar of tabs over the terminal in front.
///
/// Each tab is a `TerminalPaneView`, the agent's own terminal component: selection, search, links,
/// resizing and whatever the main terminal learns next come with it. Only the drawer of the
/// session on screen is mounted; the others' shells go on running in the terminal host, and their
/// surfaces replay its history when they come back.
struct TerminalDrawerView: View {
  let model: AppModel
  let drawer: SessionTerminalDrawer
  let sessionName: String

  var body: some View {
    VStack(spacing: 0) {
      DrawerTabBar(model: model, drawer: drawer)
      Divider()
      ZStack {
        ForEach(drawer.terminals) { terminal in
          let isActive = terminal.id == drawer.activeTerminalID
          TerminalPaneView(
            model: terminal.pane, autoStart: false, isActive: isActive,
            accessibilityTitle: accessibilityTitle(of: terminal), showsStatusBar: false,
            claimsKeyboardOnActivation: false
          )
          .overlay(alignment: .bottom) {
            if let status = terminal.exitStatus {
              ShellEndedBar(
                status: status,
                relaunch: { Task { await drawer.relaunch(terminal.id) } },
                close: { Task { await drawer.close(terminal.id) } })
            }
          }
          .opacity(isActive ? 1 : 0)
          .allowsHitTesting(isActive)
          .accessibilityHidden(!isActive)
        }
      }
      // The session's own zone stops above the drawer: a drop here is typed into the terminal in
      // front, never into the agent's (#139).
      .modifier(DrawerDropZone(model: model, drawer: drawer))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Side Terminals", bundle: .module))
    .onAppear { drawer.isOnScreen = true }
    .onDisappear { drawer.isOnScreen = false }
  }

  /// "Side terminal — npm run dev — <session>".
  private func accessibilityTitle(of terminal: DrawerTerminal) -> String {
    String(
      localized: "Side terminal — \(terminal.title) — \(sessionName)", bundle: .module,
      comment: "What VoiceOver calls a side terminal: its title, then its session's name.")
  }
}

/// The tabs, the + and the button that puts the drawer away.
private struct DrawerTabBar: View {
  let model: AppModel
  let drawer: SessionTerminalDrawer

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          ForEach(Array(drawer.terminals.enumerated()), id: \.element.id) { index, terminal in
            DrawerTab(
              model: model, drawer: drawer, terminal: terminal, index: index,
              count: drawer.terminals.count)
            Divider()
          }
        }
      }
      Button {
        model.newDrawerTerminal()
      } label: {
        Image(systemName: "plus")
          .frame(width: 28, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!drawer.canAddTerminal)
      .help(Text("New Terminal (⌘T)", bundle: .module))
      .accessibilityLabel(Text("New Terminal", bundle: .module))
      Spacer(minLength: 0)
      Button {
        model.toggleDrawer()
      } label: {
        Image(systemName: "chevron.down")
          .frame(width: 28, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(Text("Hide Terminals (⌘J): their processes keep running", bundle: .module))
      .accessibilityLabel(Text("Hide Terminals", bundle: .module))
    }
    .frame(height: 28)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Terminal tabs", bundle: .module))
  }
}

/// One tab: its title, a dot when it has news, and its own close button.
private struct DrawerTab: View {
  let model: AppModel
  let drawer: SessionTerminalDrawer
  let terminal: DrawerTerminal
  let index: Int
  let count: Int

  @State private var isRenaming = false
  @State private var name = ""
  @State private var dropHover: DrawerTabHover?

  private var isSelected: Bool { terminal.id == drawer.activeTerminalID }

  var body: some View {
    HStack(spacing: 2) {
      Button {
        drawer.activate(terminal.id)
      } label: {
        HStack(spacing: 6) {
          Text(verbatim: terminal.title)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
          if let news {
            DrawerNewsMark(news: news, diameter: 6)
          }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(isSelected ? .primary : .secondary)
      .accessibilityLabel(Text(verbatim: accessibilityLabel))
      .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      .accessibilityHint(Text("Double-click to rename", bundle: .module))
      .simultaneousGesture(TapGesture(count: 2).onEnded { beginRenaming() })

      Button {
        model.requestCloseDrawerTerminal(terminal.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(Text("Close Terminal (⌘W)", bundle: .module))
      .accessibilityLabel(
        Text(
          "Close \(terminal.title)", bundle: .module,
          comment: "Closes a side terminal. The argument is its title."))
    }
    .padding(.trailing, 4)
    .frame(maxWidth: 220)
    .background(isSelected ? Color(nsColor: .textBackgroundColor) : Color.clear)
    .overlay(alignment: .top) {
      if isSelected {
        Rectangle().fill(Color.accentColor).frame(height: 2)
      }
    }
    .overlay(alignment: .leading) {
      if dropHover == .reordering {
        Rectangle().fill(Color.accentColor).frame(width: 2)
      }
    }
    .overlay {
      if case .dropping(let hover) = dropHover {
        let color = hover.isRefusing ? Color.red : Color.accentColor
        Rectangle()
          .strokeBorder(color, lineWidth: 2)
          .background(color.opacity(0.12))
          .allowsHitTesting(false)
      }
    }
    .draggable(DrawerTabDrag.text(for: terminal.id))
    // One destination for both: a tab of the drawer moves here, anything else is dropped into
    // this tab's terminal (#139).
    .onDrop(
      of: DropReader.acceptedTypes,
      delegate: DrawerTabDropDelegate(
        model: model, drawer: drawer, terminalID: terminal.id, index: index, hover: $dropHover)
    )
    .clearsWhenDragEnds(dropHover != nil) { dropHover = nil }
    .contextMenu {
      Button {
        beginRenaming()
      } label: {
        Text("Rename…", bundle: .module)
      }
      Button {
        drawer.move(terminal.id, to: index - 1)
      } label: {
        Text("Move Left", bundle: .module)
      }
      .disabled(index == 0)
      Button {
        drawer.move(terminal.id, to: index + 1)
      } label: {
        Text("Move Right", bundle: .module)
      }
      .disabled(index >= count - 1)
      Divider()
      Button {
        model.requestCloseDrawerTerminal(terminal.id)
      } label: {
        Text("Close Terminal", bundle: .module)
      }
    }
    .accessibilityAction(named: Text("Rename", bundle: .module)) { beginRenaming() }
    .accessibilityAction(named: Text("Move Left", bundle: .module)) {
      drawer.move(terminal.id, to: index - 1)
    }
    .accessibilityAction(named: Text("Move Right", bundle: .module)) {
      drawer.move(terminal.id, to: index + 1)
    }
    .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
      RenameTerminalForm(name: $name) {
        drawer.rename(terminal.id, to: name)
        isRenaming = false
      } cancel: {
        isRenaming = false
      }
    }
  }

  /// New output, or a shell that ended, on a tab nobody is looking at.
  private var news: DrawerAttention? {
    guard !drawer.isSeen(terminal) else { return nil }
    if terminal.hasUnseenExit { return .ended }
    if terminal.hasUnseenOutput { return .output }
    return nil
  }

  private var accessibilityLabel: String {
    let state: String
    if let status = terminal.exitStatus {
      state = ShellEndedBar.label(of: status)
    } else if terminal.isRunningCommand {
      state = String(
        localized: "running a command", bundle: .module, comment: "A side terminal's state.")
    } else {
      state = String(
        localized: "waiting at its prompt", bundle: .module, comment: "A side terminal's state.")
    }
    var label = "\(terminal.title), \(state)"
    if !drawer.isSeen(terminal), terminal.hasUnseenOutput {
      label +=
        ", "
        + String(
          localized: "new output", bundle: .module,
          comment: "Said of a side terminal that wrote something since it was last seen.")
    }
    return label
  }

  private func beginRenaming() {
    name = terminal.customTitle ?? terminal.title
    isRenaming = true
  }
}

/// A tab of the drawer, dragged along the bar (#43): its text says which, under a prefix no drop
/// types (#139).
enum DrawerTabDrag {
  static let prefix = "vibe-manager-drawer-tab:"

  static func text(for id: TerminalID) -> String {
    prefix + id.rawValue.uuidString
  }

  static func terminalID(in text: String) -> TerminalID? {
    guard text.hasPrefix(prefix), let uuid = UUID(uuidString: String(text.dropFirst(prefix.count)))
    else { return nil }
    return TerminalID(rawValue: uuid)
  }

  /// Whether a drag's pasteboard holds a tab of a drawer, read while it hovers.
  static func carriesTab(_ pasteboard: NSPasteboard) -> Bool {
    guard let items = pasteboard.pasteboardItems, items.count == 1,
      let text = items[0].string(forType: .string)
    else { return false }
    return terminalID(in: text) != nil
  }

  /// The tab a drop carries, when it carries one and nothing else. Only text is read: never the
  /// content of a file, which a provider opened in place would give as text (#131).
  @MainActor
  static func terminalID(in providers: [NSItemProvider]) async -> TerminalID? {
    guard providers.count == 1, let provider = providers.first,
      !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
      provider.registeredContentTypesForOpenInPlace.isEmpty,
      provider.canLoadObject(ofClass: String.self)
    else { return nil }
    let text = await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: String.self) { text, _ in
        continuation.resume(returning: text)
      }
    }
    return text.flatMap(terminalID(in:))
  }
}

/// What a drag over a tab shows: where a tab would move, or the veil of a drop.
enum DrawerTabHover: Equatable {
  case reordering
  case dropping(DropHover)
}

/// The terminal in front of the drawer as a place to drop files on (#139), with the rules and the
/// veil of the session's own zone (#42).
private struct DrawerDropZone: ViewModifier {
  let model: AppModel
  let drawer: SessionTerminalDrawer
  @State private var hover: DropHover?

  func body(content: Content) -> some View {
    content
      .overlay {
        if let hover {
          DropHoverOverlay(hover: hover)
        }
      }
      .onDrop(
        of: DropReader.acceptedTypes,
        delegate: SideTerminalDropDelegate(model: model, drawer: drawer, hover: $hover)
      )
      .clearsWhenDragEnds(hover != nil) { hover = nil }
      .onChange(of: drawer.activeTerminalID) { hover = nil }
  }
}

/// A drop on the terminal in front of the drawer: typed into it, not into the agent's terminal.
struct SideTerminalDropDelegate: DropDelegate {
  let model: AppModel
  let drawer: SessionTerminalDrawer
  @Binding var hover: DropHover?

  private var route: SessionDropRoute {
    guard let id = drawer.activeTerminalID else { return .refused(.shellNotRunning) }
    return model.dropRoute(for: drawer.sessionID, target: .sideTerminal(id))
  }

  func dropEntered(info: DropInfo) {
    hover = SessionDropDelegate.hover(for: route, isButtonDown: DragEndWatch.isButtonDown())
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    let route = route
    hover = SessionDropDelegate.hover(for: route, isButtonDown: DragEndWatch.isButtonDown())
    return DropProposal(operation: route.isRefused ? .forbidden : .copy)
  }

  func dropExited(info: DropInfo) {
    hover = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    hover = nil
    guard let id = drawer.activeTerminalID, !route.isRefused else { return false }
    let providers = info.itemProviders(for: DropReader.acceptedTypes)
    let model = model
    let session = drawer.sessionID
    Task { await model.deliverDrop(providers, to: session, target: .sideTerminal(id)) }
    return true
  }
}

/// A drop on a tab of the drawer (#139): another tab of the drawer moves before it, as it did;
/// anything else is typed into this tab's terminal, which comes in front — as a drop on a row of
/// the sidebar selects its session first.
struct DrawerTabDropDelegate: DropDelegate {
  let model: AppModel
  let drawer: SessionTerminalDrawer
  let terminalID: TerminalID
  let index: Int
  @Binding var hover: DrawerTabHover?

  private var route: SessionDropRoute {
    model.dropRoute(for: drawer.sessionID, target: .sideTerminal(terminalID))
  }

  /// A file, an image or a promised file (Mail, Photos) is surely a drop to type.
  private static let fileTypes: [UTType] =
    [.fileURL, .image]
    + NSFilePromiseReceiver.readableDraggedTypes.compactMap { UTType($0) }

  /// Whether the drag hovering is a tab of a drawer. `DropInfo` cannot be read before the drop,
  /// so the drag's own pasteboard is: a tab's text is on it for the whole drag. The drop itself
  /// goes by what it carries, read then.
  private static func isTabDrag(_ info: DropInfo) -> Bool {
    !info.hasItemsConforming(to: fileTypes)
      && DrawerTabDrag.carriesTab(NSPasteboard(name: .drag))
  }

  func dropEntered(info: DropInfo) {
    track(info)
  }

  /// `.copy` for a tab too: a text view — Safari, the composer — lets its text be copied, never
  /// moved, and a proposal of `.move` would refuse it.
  func dropUpdated(info: DropInfo) -> DropProposal? {
    track(info)
    guard !Self.isTabDrag(info) else { return DropProposal(operation: .copy) }
    return DropProposal(operation: route.isRefused ? .forbidden : .copy)
  }

  private func track(_ info: DropInfo) {
    let next: DrawerTabHover?
    if Self.isTabDrag(info) {
      next = DragEndWatch.isButtonDown() ? .reordering : nil
    } else {
      next = SessionDropDelegate.hover(for: route, isButtonDown: DragEndWatch.isButtonDown())
        .map(DrawerTabHover.dropping)
    }
    if hover != next { hover = next }
  }

  func dropExited(info: DropInfo) {
    hover = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    hover = nil
    if !Self.isTabDrag(info), route.isRefused { return false }
    let providers = info.itemProviders(for: DropReader.acceptedTypes)
    let model = model
    let drawer = drawer
    let terminalID = terminalID
    let index = index
    Task { @MainActor in
      if let dragged = await DrawerTabDrag.terminalID(in: providers) {
        guard dragged != terminalID, drawer.terminals.contains(where: { $0.id == dragged })
        else { return }
        drawer.move(dragged, to: index)
        return
      }
      // A shell that ended takes nothing and stays behind: the drop says why, and that is all.
      let target = SessionDropTarget.sideTerminal(terminalID)
      if !model.dropRoute(for: drawer.sessionID, target: target).isRefused {
        drawer.activate(terminalID)
      }
      await model.deliverDrop(providers, to: drawer.sessionID, target: .sideTerminal(terminalID))
    }
    return true
  }
}

private struct RenameTerminalForm: View {
  @Binding var name: String
  let commit: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(text: $name) {
        Text("Name", bundle: .module)
      }
      .textFieldStyle(.roundedBorder)
      .frame(width: 220)
      .onSubmit(commit)
      Text("Leave empty to follow the shell's folder or command.", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(action: cancel) {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        Button(action: commit) {
          Text("Rename", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(14)
  }
}

/// Over a tab whose shell ended with an error or a signal: what happened, and the two ways on.
private struct ShellEndedBar: View {
  let status: TerminalPaneModel.Status
  let relaunch: () -> Void
  let close: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(verbatim: Self.label(of: status))
        .font(.callout)
      Spacer()
      Button(action: relaunch) {
        Text("Restart", bundle: .module, comment: "Starts a new shell in a side terminal.")
      }
      .controlSize(.small)
      Button(action: close) {
        Text("Close", bundle: .module, comment: "Closes a side terminal.")
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.regularMaterial)
    .accessibilityElement(children: .contain)
  }

  static func label(of status: TerminalPaneModel.Status) -> String {
    switch status {
    case .exited(let code):
      return String(
        localized: "The shell ended with code \(String(code)).", bundle: .module,
        comment: "Over a side terminal whose shell ended. The argument is its exit status.")
    case .terminated(let signal):
      return String(
        localized: "The shell was stopped by signal \(String(signal)).", bundle: .module,
        comment: "Over a side terminal whose shell was killed. The argument is a signal number.")
    case .starting, .running, .failed:
      return ""
    }
  }
}

/// The mark of a terminal nobody is looking at: blue for new output, orange for a shell that
/// ended. With Differentiate Without Color, an ended shell is a ring rather than a dot, so the two
/// differ by more than their colour (#231). VoiceOver hears the state in the tab's own label.
struct DrawerNewsMark: View {
  let news: DrawerAttention
  let diameter: CGFloat

  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

  /// Whether the mark is a ring: an ended shell, when colour must not be all that tells it apart.
  static func isRing(_ news: DrawerAttention, differentiatingWithoutColor: Bool) -> Bool {
    news == .ended && differentiatingWithoutColor
  }

  var body: some View {
    let colour = news == .ended ? Color.orange : Color.accentColor
    Group {
      if Self.isRing(news, differentiatingWithoutColor: differentiateWithoutColor) {
        Circle().strokeBorder(colour, lineWidth: 1.5)
      } else {
        Circle().fill(colour)
      }
    }
    .frame(width: diameter, height: diameter)
    .accessibilityHidden(true)
  }
}

/// The status bar's button (#43): shows or hides the drawer, counts its tabs, and says when a
/// terminal nobody is looking at wrote something, or ended.
struct DrawerStatusButton: View {
  let model: AppModel
  let session: WorkSession

  var body: some View {
    let drawer = model.canUseDrawer(session) ? model.terminals?.drawer(for: session.id) : nil
    let count = drawer?.terminalCount ?? 0
    let isShown = drawer.map { $0.isVisible && !$0.terminals.isEmpty } ?? false
    let attention = drawer?.attention ?? DrawerAttention.none
    Button {
      guard model.selectedSessionID == session.id else { return }
      model.toggleDrawer()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "apple.terminal")
        if count > 0 {
          Text(verbatim: "\(count)")
            .monospacedDigit()
        }
      }
      .overlay(alignment: .topTrailing) {
        if attention != DrawerAttention.none {
          DrawerNewsMark(news: attention, diameter: 7)
            .offset(x: 5, y: -3)
        }
      }
    }
    .controlSize(.small)
    .disabled(drawer == nil)
    .help(help(drawer: drawer, isShown: isShown))
    .accessibilityLabel(Text(verbatim: accessibilityLabel(drawer: drawer, count: count)))
    .accessibilityValue(
      isShown
        ? Text("Shown", bundle: .module, comment: "The drawer of side terminals is shown.")
        : Text("Hidden", bundle: .module, comment: "The drawer of side terminals is hidden."))
  }

  private func help(drawer: SessionTerminalDrawer?, isShown: Bool) -> Text {
    guard drawer != nil else {
      return Text("Reopen the session to find its terminals again", bundle: .module)
    }
    return isShown
      ? Text("Hide Terminals (⌘J)", bundle: .module)
      : Text("Show Terminals (⌘J)", bundle: .module)
  }

  private func accessibilityLabel(drawer: SessionTerminalDrawer?, count: Int) -> String {
    var label = String(
      localized: "Side terminals, \(count) open", bundle: .module,
      comment: "The status bar's button of the drawer of side terminals, for VoiceOver.")
    if let terminal = drawer?.noticeTerminal {
      label +=
        ", "
        + (terminal.hasUnseenExit
          ? String(
            localized: "\(terminal.title) ended", bundle: .module,
            comment: "Said of a hidden side terminal whose shell ended. The argument is its title.")
          : String(
            localized: "new output in \(terminal.title)", bundle: .module,
            comment:
              "Said of a hidden side terminal that wrote something. The argument is its title."
          ))
    }
    return label
  }
}
