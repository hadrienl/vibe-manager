import SwiftUI
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
  @State private var isDropTarget = false

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
          if let tint = newsTint {
            Circle()
              .fill(tint)
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
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
      if isDropTarget {
        Rectangle().fill(Color.accentColor).frame(width: 2)
      }
    }
    .draggable(terminal.id.rawValue.uuidString)
    .dropDestination(for: String.self) { items, _ in
      guard let raw = items.first, let uuid = UUID(uuidString: raw) else { return false }
      let dragged = TerminalID(rawValue: uuid)
      guard dragged != terminal.id, drawer.terminals.contains(where: { $0.id == dragged }) else {
        return false
      }
      drawer.move(dragged, to: index)
      return true
    } isTargeted: {
      isDropTarget = $0
    }
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

  /// Blue for new output, orange for a shell that ended, on a tab nobody is looking at.
  private var newsTint: Color? {
    guard !drawer.isSeen(terminal) else { return nil }
    if terminal.hasUnseenExit { return .orange }
    if terminal.hasUnseenOutput { return .accentColor }
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
          Circle()
            .fill(attention == .ended ? Color.orange : Color.accentColor)
            .frame(width: 7, height: 7)
            .offset(x: 5, y: -3)
            .accessibilityHidden(true)
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
