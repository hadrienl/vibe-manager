import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeBrowser
import VibeConversationUI
import VibeDomain

/// The button the session's tabs open from (#536): the tab in front, its whole title, and how many
/// there are. The tabs themselves are listed one above the other, where a title is read whole.
struct BrowserTabPickerButton: View {
  let browser: SessionBrowser
  @Binding var isShowingTabs: Bool
  /// When the list last closed.
  @State private var closedAt = Date.distantPast

  var body: some View {
    Button {
      // The list closes on the mouse-down outside it, before this button acts on the mouse-up: a
      // click meant to close it would open it again.
      guard isShowingTabs || Date().timeIntervalSince(closedAt) > 0.3 else { return }
      isShowingTabs.toggle()
    } label: {
      HStack(spacing: 6) {
        if let tab = browser.activeTab {
          BrowserTabIcon(tab: tab)
            .foregroundStyle(.secondary)
        }
        title
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        // An agent acting in a tab behind: seen without opening the list, as the strip showed it.
        if isAgentActingBehind {
          Image(systemName: "sparkle")
            .foregroundStyle(Color.accentColor)
            .padding(2)
            .background(Circle().fill(Color.accentColor.opacity(0.25)))
            .accessibilityHidden(true)
        }
        Text(verbatim: "\(browser.allTabs.count)")
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.primary.opacity(0.07)))
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .font(.callout.weight(.semibold))
      .padding(.leading, 8)
      .padding(.trailing, 7)
      .frame(maxWidth: .infinity)
      .frame(height: 26)
      .background(
        RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(
            isShowingTabs ? Color.accentColor : Color(nsColor: .separatorColor))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onChange(of: isShowingTabs) { _, isShowing in
      if !isShowing { closedAt = Date() }
    }
    .instantTooltip(browser.activeTab.map { Text(verbatim: $0.url.absoluteString) })
    .accessibilityLabel(
      Text("Show Tabs", bundle: .module, comment: "The web view's button that lists its tabs.")
    )
    .accessibilityValue(title)
  }

  private var isAgentActingBehind: Bool {
    browser.allTabs.contains { $0.isAgentActing && $0.id != browser.activeTab?.id }
  }

  /// The ticket's tab goes by its ticket, then its page.
  private var title: Text {
    guard let tab = browser.activeTab else { return Text("No Tabs", bundle: .module) }
    if tab.isPinnedTicket, let label = browser.ticket?.label {
      return Text(verbatim: "\(label) \(tab.displayTitle)")
    }
    return BrowserTabTitle.text(of: tab)
  }
}

/// The session's tabs, one above the other (#536): the pinned ones first, the ticket's at their
/// head, each title on up to two lines. Dragging a row moves its tab, and pins or unpins it when it
/// is dropped among the other group.
struct BrowserTabList: View {
  let model: AppModel
  let workspace: BrowserWorkspace
  let browser: SessionBrowser
  let dismiss: () -> Void
  /// The row the arrow keys are on.
  @State private var highlighted: BrowserTabID?
  @State private var dropIndicator: BrowserTabDropIndicator?
  /// The tab being dragged from this list: only a tab of its own is dropped into it.
  @State private var dragged: BrowserTabID?
  @FocusState private var hasKeyboard: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Grows with the tabs, then scrolls.
      ViewThatFits(in: .vertical) {
        rows
        ScrollViewReader { proxy in
          ScrollView { rows }
            .onChange(of: highlighted) { _, id in
              if let id { proxy.scrollTo(id) }
            }
        }
      }
      .frame(maxHeight: 420)
      separator
      Button {
        dismiss()
        model.newWebTab()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "plus")
            .foregroundStyle(.secondary)
            .frame(width: 18)
          Text("New Tab", bundle: .module)
          Spacer(minLength: 8)
          Text(verbatim: "⌘T")
            .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(BrowserTabListButtonStyle())
    }
    .padding(5)
    .focusable()
    .focusEffectDisabled()
    .focused($hasKeyboard)
    // Only while the list itself has the keyboard: with Full Keyboard Access on a row's button,
    // the keys are that button's.
    .onKeyPress(.downArrow) {
      guard hasKeyboard else { return .ignored }
      moveHighlight(by: 1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      guard hasKeyboard else { return .ignored }
      moveHighlight(by: -1)
      return .handled
    }
    .onKeyPress(.return) {
      guard hasKeyboard, let highlighted else { return .ignored }
      activate(highlighted)
      return .handled
    }
    .clearsWhenDragEnds(dragged != nil || dropIndicator != nil) {
      dragged = nil
      dropIndicator = nil
    }
    .onAppear {
      highlighted = browser.activeTab?.id
      hasKeyboard = true
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Web tabs", bundle: .module))
  }

  /// In the order the browser keeps them: the ticket's, the pinned tabs, the others.
  private var rows: some View {
    let pinned = (browser.ticketTab.map { [$0] } ?? []) + browser.tabs.prefix(browser.pinnedCount)
    let others = Array(browser.tabs.dropFirst(browser.pinnedCount))
    return VStack(alignment: .leading, spacing: 1) {
      if !pinned.isEmpty {
        header(
          Text(
            "Pinned", bundle: .module,
            comment: "A heading in the list of web tabs, above the tabs the user pinned."))
        ForEach(pinned) { row($0) }
        if !others.isEmpty {
          separator
          header(
            Text(
              "Tabs", bundle: .module,
              comment: "A heading in the list of web tabs, above the tabs that are not pinned."))
        }
      }
      ForEach(others) { row($0) }
    }
  }

  private var separator: some View {
    Divider()
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
  }

  private func header(_ text: Text) -> some View {
    text
      .font(.caption.weight(.semibold))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 8)
      .padding(.top, 4)
      .padding(.bottom, 1)
      .accessibilityAddTraits(.isHeader)
  }

  private func row(_ tab: BrowserTabModel) -> some View {
    BrowserTabRow(
      tab: tab, browser: browser, model: model,
      isActive: browser.activeTab?.id == tab.id,
      isHighlighted: highlighted == tab.id,
      dropIndicator: $dropIndicator, dragged: $dragged,
      activate: { activate(tab.id) },
      close: { workspace.close(tab.id, in: browser.sessionID) }
    )
    .id(tab.id)
  }

  private func activate(_ id: BrowserTabID) {
    browser.activate(id)
    dismiss()
  }

  private func moveHighlight(by offset: Int) {
    let ids = browser.allTabs.map(\.id)
    guard !ids.isEmpty else { return }
    let current = highlighted.flatMap { ids.firstIndex(of: $0) }
    let next = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? 0
    highlighted = ids[next]
  }
}

/// One tab of the list: its icon, its title on up to two lines, where it is, and what can be done
/// to it.
private struct BrowserTabRow: View {
  let tab: BrowserTabModel
  let browser: SessionBrowser
  let model: AppModel
  let isActive: Bool
  let isHighlighted: Bool
  @Binding var dropIndicator: BrowserTabDropIndicator?
  @Binding var dragged: BrowserTabID?
  let activate: () -> Void
  let close: () -> Void
  @State private var isHovering = false
  @State private var height: CGFloat = 0
  @FocusState private var focus: RowFocus?

  /// What has the keyboard in the row, with Full Keyboard Access (#230).
  private enum RowFocus: Hashable {
    case tab
    case pin
    case close
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // A button, so that the keyboard reaches every tab (#230).
      Button(action: activate) {
        HStack(alignment: .top, spacing: 8) {
          BrowserTabIcon(tab: tab)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .padding(.top, 1)
          VStack(alignment: .leading, spacing: 1) {
            BrowserTabTitle.text(of: tab)
              .font(.callout.weight(isActive ? .semibold : .regular))
              .foregroundStyle(.primary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            subtitle
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($focus, equals: .tab)

      if tab.isPinnedTicket {
        Image(systemName: "pin.fill")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .frame(width: 20, height: 20)
          .padding(.top, 5)
          .padding(.trailing, 6)
          .accessibilityHidden(true)
      } else {
        HStack(spacing: 0) {
          pinButton
          closeButton
        }
        .padding(.top, 5)
        .padding(.trailing, 6)
      }
    }
    .background(RoundedRectangle(cornerRadius: 6).fill(background))
    .overlay(alignment: dropsAfter == true ? .bottom : .top) {
      if dropsAfter != nil {
        Capsule()
          .fill(Color.accentColor)
          .frame(height: 2)
          .padding(.horizontal, 6)
          .offset(y: dropsAfter == true ? 1 : -1)
      }
    }
    .contentShape(Rectangle())
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      height = $0
    }
    .modifier(BrowserTabRowDrag(tab: tab, dragged: $dragged))
    .onDrop(
      of: [.text],
      delegate: BrowserTabDropDelegate(
        target: tab.id, isTicket: tab.isPinnedTicket, height: height, dragged: $dragged,
        indicator: $dropIndicator,
        move: { [browser] id, target, after in browser.move(id, nextTo: target, after: after) })
    )
    .onHover { isHovering = $0 }
    .instantTooltip(Text(verbatim: tab.url.absoluteString))
    .contextMenu {
      BrowserTabMenu(tab: tab, browser: browser, model: model, close: close)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(BrowserTabTitle.accessibilityLabel(of: tab, in: browser))
    .accessibilityValue(tab.isPinned ? Text("Pinned Tab", bundle: .module) : Text(verbatim: ""))
    .accessibilityAction { activate() }
    .accessibilityActions {
      if !tab.isPinnedTicket {
        Button(String(localized: "Close Tab", bundle: .module), action: close)
        Button(pinTitle) { browser.setPinned(tab.id, !tab.isPinned) }
        if browser.canMoveTab(tab.id, by: -1) {
          Button(String(localized: "Move Up", bundle: .module)) { browser.moveTab(tab.id, by: -1) }
        }
        if browser.canMoveTab(tab.id, by: 1) {
          Button(String(localized: "Move Down", bundle: .module)) { browser.moveTab(tab.id, by: 1) }
        }
      }
    }
  }

  /// Where a tab dragged over this row would go: after it, before it, or `nil` when none is.
  private var dropsAfter: Bool? {
    dropIndicator?.target == tab.id ? dropIndicator?.after : nil
  }

  private var background: Color {
    if isActive { return Color.accentColor.opacity(0.16) }
    if isHovering || isHighlighted { return Color.primary.opacity(0.06) }
    return .clear
  }

  /// Under the pointer, with the keyboard on the row, and always once the tab is pinned.
  private var pinButton: some View {
    let isShown = tab.isPinned || isHovering || focus != nil
    return Button {
      browser.setPinned(tab.id, !tab.isPinned)
    } label: {
      Image(systemName: tab.isPinned ? "pin.fill" : "pin")
        .font(.system(size: 10))
        .foregroundStyle(tab.isPinned ? Color.accentColor : .secondary)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .focused($focus, equals: .pin)
    .opacity(isShown ? 1 : 0)
    .allowsHitTesting(isShown)
    .instantTooltip(Text(pinTitle))
  }

  /// On the tab in front, under the pointer, and with the keyboard on the row.
  private var closeButton: some View {
    let isShown = isActive || isHovering || focus != nil
    return Button(action: close) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        // At least 20 points to click (#229).
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .focused($focus, equals: .close)
    .opacity(isShown ? 1 : 0)
    .allowsHitTesting(isShown)
    .instantTooltip(Text("Close Tab", bundle: .module))
  }

  private var pinTitle: String {
    tab.isPinned
      ? String(localized: "Unpin Tab", bundle: .module)
      : String(localized: "Pin Tab", bundle: .module)
  }

  /// The ticket, a page of this Mac, and the site.
  private var subtitle: some View {
    HStack(spacing: 5) {
      if tab.isPinnedTicket, let label = browser.ticket?.label {
        Text(verbatim: label)
          .fontWeight(.semibold)
          .foregroundStyle(.primary)
      }
      if tab.origin?.isLocal == true {
        BrowserLocalBadge()
      }
      if let address {
        Text(verbatim: address)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private var address: String? {
    guard !tab.isBlank else { return nil }
    return tab.origin?.description ?? tab.url.absoluteString
  }
}

/// A row dragged elsewhere in the list: marked, so that a tab let go over the session is not typed
/// into its agent (#42). The ticket's tab stays where it is.
private struct BrowserTabRowDrag: ViewModifier {
  let tab: BrowserTabModel
  @Binding var dragged: BrowserTabID?

  func body(content: Content) -> some View {
    if tab.isPinnedTicket {
      content
    } else {
      content.onDrag {
        dragged = tab.id
        return NSItemProvider(object: BrowserTabDrag.text(for: tab.id) as NSString)
      }
    }
  }
}

/// Where a dragged tab would land: before or after the row it is over.
struct BrowserTabDropIndicator: Equatable {
  let target: BrowserTabID
  let after: Bool
}

/// Shows where a tab dragged over a row would go, and moves it there when it is let go. Only a
/// tab dragged from the list is taken: text or a link from elsewhere is refused.
private struct BrowserTabDropDelegate: DropDelegate {
  let target: BrowserTabID
  /// Dropped on the ticket's tab, a tab becomes the first pinned one: after it, always.
  let isTicket: Bool
  let height: CGFloat
  @Binding var dragged: BrowserTabID?
  @Binding var indicator: BrowserTabDropIndicator?
  let move: (BrowserTabID, BrowserTabID, Bool) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    dragged != nil
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard dragged != nil else { return DropProposal(operation: .forbidden) }
    let next = BrowserTabDropIndicator(target: target, after: isAfter(info))
    // Once per change, not on every move of the pointer: each write draws the list again.
    if indicator != next { indicator = next }
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if indicator?.target == target { indicator = nil }
  }

  func performDrop(info: DropInfo) -> Bool {
    indicator = nil
    guard let id = dragged else { return false }
    dragged = nil
    move(id, target, isAfter(info))
    return true
  }

  private func isAfter(_ info: DropInfo) -> Bool {
    isTicket || info.location.y > height / 2
  }
}

/// What a tab's context menu offers, in the list.
private struct BrowserTabMenu: View {
  let tab: BrowserTabModel
  let browser: SessionBrowser
  let model: AppModel
  let close: () -> Void

  var body: some View {
    Button {
      tab.reload()
    } label: {
      Text("Reload", bundle: .module)
    }
    Button {
      model.openOutside(tab.url)
    } label: {
      Text("Open in Browser", bundle: .module)
    }
    .disabled(!model.opensOutside(tab.url))
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
    } label: {
      Text("Copy Address", bundle: .module)
    }
    if !tab.isPinnedTicket, let id = model.selectedSessionID {
      Button {
        Task { await model.setTicket(tab.url.absoluteString, for: id) }
      } label: {
        Text("Set as Ticket", bundle: .module)
      }
      Divider()
      Button {
        browser.setPinned(tab.id, !tab.isPinned)
      } label: {
        tab.isPinned ? Text("Unpin Tab", bundle: .module) : Text("Pin Tab", bundle: .module)
      }
      Button {
        browser.moveTab(tab.id, by: -1)
      } label: {
        Text("Move Up", bundle: .module)
      }
      .disabled(!browser.canMoveTab(tab.id, by: -1))
      Button {
        browser.moveTab(tab.id, by: 1)
      } label: {
        Text("Move Down", bundle: .module)
      }
      .disabled(!browser.canMoveTab(tab.id, by: 1))
      Divider()
      Button(action: close) {
        Text("Close Tab", bundle: .module)
      }
    }
  }
}

/// Where a tab comes from: the ticket, an agent, a link of the terminal, or the user.
struct BrowserTabIcon: View {
  let tab: BrowserTabModel

  var body: some View {
    if tab.isLoading {
      ProgressView().controlSize(.mini)
    } else if tab.isPinnedTicket {
      Image(systemName: "ticket")
    } else if tab.openedBy == .agent {
      Image(systemName: "sparkle")
        .foregroundStyle(Color.accentColor)
        .padding(2)
        .background(
          Circle().fill(tab.isAgentActing ? Color.accentColor.opacity(0.25) : .clear))
    } else if tab.openedBy == .terminalLink {
      Image(systemName: "terminal")
    } else {
      Image(systemName: "globe")
    }
  }
}

/// What a tab is called, on screen and to VoiceOver.
enum BrowserTabTitle {
  /// An empty tab is a New Tab, never `about:blank`.
  @MainActor
  static func text(of tab: BrowserTabModel) -> Text {
    tab.isBlank && tab.title.isEmpty
      ? Text("New Tab", bundle: .module) : Text(verbatim: tab.displayTitle)
  }

  @MainActor
  static func accessibilityLabel(of tab: BrowserTabModel, in browser: SessionBrowser) -> Text {
    if tab.isPinnedTicket {
      return Text("Ticket tab, \(browser.ticket?.label ?? tab.displayTitle)", bundle: .module)
    }
    if tab.isAgentActing {
      return Text("\(tab.displayTitle), opened by the agent, the agent is acting", bundle: .module)
    }
    if tab.openedBy == .agent {
      return Text("\(tab.displayTitle), opened by the agent", bundle: .module)
    }
    return text(of: tab)
  }
}

/// A page of this Mac, which the agent may act on without asking.
struct BrowserLocalBadge: View {
  var body: some View {
    Text("LOCAL", bundle: .module, comment: "A badge in the address bar for a page of this Mac.")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .foregroundStyle(.green)
      .background(RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.12)))
      .instantTooltip(
        Text("A page of this Mac: the agent may act on it without asking.", bundle: .module))
  }
}

/// A row of the list that is a plain action: lit under the pointer.
private struct BrowserTabListButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    BrowserTabListButton(configuration: configuration)
  }

  private struct BrowserTabListButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0))
        )
        .onHover { isHovering = $0 }
    }
  }
}
