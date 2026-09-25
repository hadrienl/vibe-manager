import AppKit
import SwiftUI
import VibeApplication
import VibeBrowser
import VibeDomain
import WebKit

/// The session's web view, beside its terminal (#69): its tabs, an address bar, the page, and what
/// agents asked or did there.
struct BrowserPanel: View {
  let model: AppModel
  let workspace: BrowserWorkspace
  let browser: SessionBrowser

  var body: some View {
    VStack(spacing: 0) {
      BrowserTabStrip(model: model, workspace: workspace, browser: browser)
      Divider()
      BrowserAddressBar(model: model, browser: browser, tab: browser.activeTab)
      Divider()
      ZStack(alignment: .top) {
        content
        if let request = workspace.requests(for: browser.sessionID).first {
          BrowserPermissionBanner(request: request) { answer in
            workspace.answer(request, with: answer)
          }
          .padding(10)
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Web view", bundle: .module))
  }

  @ViewBuilder
  private var content: some View {
    if let tab = browser.activeTab {
      ZStack {
        BrowserWebViewHost(
          workspace: workspace, tab: tab, focusRequest: model.webViewFocusRequest,
          isPageFocused: { model.isWebPageFocused = $0 })
        if let failure = tab.failure {
          BrowserFailureView(tab: tab, failure: failure)
        } else if tab.hasCrashed {
          BrowserStateView(
            symbol: "exclamationmark.octagon", tint: .red,
            title: Text("This page crashed", bundle: .module),
            message: Text(
              "Its web content process stopped. Other tabs and the terminal were not affected.",
              bundle: .module)
          ) {
            Button {
              tab.reload()
            } label: {
              Text("Reload", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    } else {
      BrowserEmptyView(model: model)
    }
  }
}

// MARK: - Tabs

private struct BrowserTabStrip: View {
  let model: AppModel
  let workspace: BrowserWorkspace
  let browser: SessionBrowser
  @State private var isShowingTrace = false

  var body: some View {
    HStack(spacing: 4) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(browser.allTabs) { tab in
            BrowserTabButton(
              tab: tab, isActive: browser.activeTab?.id == tab.id,
              activate: { browser.activate(tab.id) },
              close: { workspace.close(tab.id, in: browser.sessionID) },
              model: model, browser: browser
            )
            .draggable(tab.id.rawValue.uuidString)
            .dropDestination(for: String.self) { items, _ in
              guard let raw = items.first, let uuid = UUID(uuidString: raw),
                let destination = browser.tabs.firstIndex(where: { $0.id == tab.id })
              else { return false }
              browser.move(BrowserTabID(rawValue: uuid), to: destination)
              return true
            }
          }
        }
        .padding(.horizontal, 6)
      }
      Button {
        model.focusAddressBar()
      } label: {
        Image(systemName: "plus")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .help(Text("New Tab", bundle: .module))
      .accessibilityLabel(Text("New Tab", bundle: .module))

      Spacer(minLength: 0)

      Button {
        isShowingTrace.toggle()
        browser.markTraceSeen()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "clock.arrow.circlepath")
          if browser.unseenActionCount > 0 {
            Text(verbatim: "\(min(browser.unseenActionCount, 99))")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(Color.accentColor))
              .foregroundStyle(.white)
          }
        }
        .frame(height: 24)
      }
      .buttonStyle(.borderless)
      .padding(.trailing, 8)
      .help(Text("Agent Actions", bundle: .module))
      .accessibilityLabel(Text("Agent Actions", bundle: .module))
      .accessibilityValue(
        Text(
          "\(browser.unseenActionCount) new", bundle: .module,
          comment: "How many agent actions were recorded since the trace was last opened.")
      )
      .popover(isPresented: $isShowingTrace, arrowEdge: .bottom) {
        BrowserTracePopover(browser: browser) { workspace.clearTrace(of: browser.sessionID) }
      }
    }
    .frame(height: 36)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Web tabs", bundle: .module))
  }
}

private struct BrowserTabButton: View {
  let tab: BrowserTabModel
  let isActive: Bool
  let activate: () -> Void
  let close: () -> Void
  let model: AppModel
  let browser: SessionBrowser
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 5) {
      icon
      if tab.isPinnedTicket {
        Text(verbatim: browser.ticket?.label ?? tab.displayTitle)
          .lineLimit(1)
      } else {
        Text(verbatim: tab.displayTitle)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 150, alignment: .leading)
        if isActive || isHovering {
          Button(action: close) {
            Image(systemName: "xmark")
              .font(.system(size: 9, weight: .semibold))
              .frame(width: 14, height: 14)
          }
          .buttonStyle(.borderless)
          .help(Text("Close Tab", bundle: .module))
          .accessibilityLabel(Text("Close Tab", bundle: .module))
        }
      }
    }
    .font(.callout.weight(isActive ? .semibold : .regular))
    .foregroundStyle(isActive ? .primary : .secondary)
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(isActive ? Color(nsColor: .controlBackgroundColor) : .clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(isActive ? Color(nsColor: .separatorColor) : .clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: activate)
    .onHover { isHovering = $0 }
    .help(Text(verbatim: tab.url.absoluteString))
    .contextMenu { menu }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAction(named: Text("Close Tab", bundle: .module)) { close() }
    .accessibilityAction { activate() }
  }

  @ViewBuilder
  private var icon: some View {
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

  private var accessibilityLabel: Text {
    let title = Text(verbatim: tab.displayTitle)
    if tab.isPinnedTicket {
      return Text("Ticket tab, \(browser.ticket?.label ?? tab.displayTitle)", bundle: .module)
    }
    if tab.isAgentActing {
      return Text("\(tab.displayTitle), opened by the agent, the agent is acting", bundle: .module)
    }
    if tab.openedBy == .agent {
      return Text("\(tab.displayTitle), opened by the agent", bundle: .module)
    }
    return title
  }

  @ViewBuilder
  private var menu: some View {
    Button {
      tab.reload()
    } label: {
      Text("Reload", bundle: .module)
    }
    Button {
      NSWorkspace.shared.open(tab.url)
    } label: {
      Text("Open in Browser", bundle: .module)
    }
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
      Button(action: close) {
        Text("Close Tab", bundle: .module)
      }
    }
  }
}

// MARK: - Address bar

private struct BrowserAddressBar: View {
  let model: AppModel
  let browser: SessionBrowser
  let tab: BrowserTabModel?
  @State private var text = ""
  @State private var isEditingTicket = false
  @State private var ticketText = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 2) {
      Button {
        tab?.goBack()
      } label: {
        Image(systemName: "chevron.left").frame(width: 26, height: 24)
      }
      .disabled(!(tab?.canGoBack ?? false))
      .help(Text("Back", bundle: .module))
      .accessibilityLabel(Text("Back", bundle: .module))

      Button {
        tab?.goForward()
      } label: {
        Image(systemName: "chevron.right").frame(width: 26, height: 24)
      }
      .disabled(!(tab?.canGoForward ?? false))
      .help(Text("Forward", bundle: .module))
      .accessibilityLabel(Text("Forward", bundle: .module))

      Button {
        guard let tab else { return }
        if tab.isLoading { tab.stopLoading() } else { tab.reload() }
      } label: {
        Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
          .frame(width: 26, height: 24)
      }
      .disabled(tab == nil)
      .help(
        tab?.isLoading == true ? Text("Stop", bundle: .module) : Text("Reload", bundle: .module)
      )
      .accessibilityLabel(
        tab?.isLoading == true ? Text("Stop", bundle: .module) : Text("Reload", bundle: .module))

      HStack(spacing: 6) {
        originBadge
        TextField(text: $text, prompt: Text("Enter an address or #ticket", bundle: .module)) {
          Text("Address", bundle: .module)
        }
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onSubmit {
          model.navigateWebTab(to: text)
          isFocused = false
        }
        .onExitCommand {
          text = tab?.url.absoluteString ?? ""
          isFocused = false
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(
        RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor))
      )
      .padding(.horizontal, 4)

      Button {
        if let url = tab?.url { NSWorkspace.shared.open(url) }
      } label: {
        Image(systemName: "arrow.up.forward.app").frame(width: 26, height: 24)
      }
      .disabled(tab == nil)
      .help(Text("Open in Browser", bundle: .module))
      .accessibilityLabel(Text("Open in Browser", bundle: .module))

      Menu {
        ticketMenu
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 30)
      .help(Text("More", bundle: .module))
      .accessibilityLabel(Text("More", bundle: .module))
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 6)
    .frame(height: 38)
    .overlay(alignment: .bottom) {
      if let tab, tab.isLoading {
        GeometryReader { proxy in
          Rectangle()
            .fill(Color.accentColor)
            .frame(width: proxy.size.width * max(tab.progress, 0.05), height: 2)
        }
        .frame(height: 2)
      }
    }
    .onAppear { text = tab?.url.absoluteString ?? "" }
    .onChange(of: tab?.url) { _, url in
      if !isFocused { text = url?.absoluteString ?? "" }
    }
    .onChange(of: tab?.id) { _, _ in
      text = tab?.url.absoluteString ?? ""
    }
    .onChange(of: model.addressBarFocusRequest) { _, _ in
      isFocused = true
    }
    .onChange(of: isFocused) { _, focused in
      model.isAddressBarFocused = focused
    }
    .onDisappear { model.isAddressBarFocused = false }
    .alert(Text("Ticket", bundle: .module), isPresented: $isEditingTicket) {
      TextField(text: $ticketText) {
        Text("Ticket address or #number", bundle: .module)
      }
      Button {
        guard let id = model.selectedSessionID else { return }
        let value = ticketText
        Task { await model.setTicket(value, for: id) }
      } label: {
        Text("Set Ticket", bundle: .module)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: {
      Text(
        "The ticket's page stays pinned first among this session's tabs. Leave the field empty to remove it.",
        bundle: .module)
    }
  }

  @ViewBuilder
  private var originBadge: some View {
    if let origin = tab?.origin, tab?.failure == nil {
      if origin.isLocal {
        Text(
          "LOCAL", bundle: .module, comment: "A badge in the address bar for a page of this Mac."
        )
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .foregroundStyle(.green)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.12)))
        .help(Text("A page of this Mac: the agent may act on it without asking.", bundle: .module))
      } else if origin.scheme == "https" {
        Image(systemName: "lock.fill")
          .foregroundStyle(.secondary)
          .font(.caption)
          .accessibilityLabel(Text("Secure connection", bundle: .module))
      }
    }
  }

  @ViewBuilder
  private var ticketMenu: some View {
    Button {
      guard let url = tab?.url else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.absoluteString, forType: .string)
    } label: {
      Text("Copy Address", bundle: .module)
    }
    .disabled(tab == nil)
    Divider()
    if let id = model.selectedSessionID {
      if let tab, !tab.isPinnedTicket {
        Button {
          Task { await model.setTicket(tab.url.absoluteString, for: id) }
        } label: {
          Text("Set as Ticket", bundle: .module)
        }
      }
      Button {
        ticketText = browser.ticket?.url.absoluteString ?? ""
        isEditingTicket = true
      } label: {
        Text("Change Ticket…", bundle: .module)
      }
      if let ticket = browser.ticket {
        Button {
          Task { await model.setTicket("", for: id) }
        } label: {
          Text("Remove Ticket", bundle: .module)
        }
        if ticket.origin != .branch {
          Button {
            Task { await model.resetTicket(for: id) }
          } label: {
            Text("Use the Branch's Ticket", bundle: .module)
          }
        }
      } else if model.selectedSession?.ticket != nil {
        Button {
          Task { await model.resetTicket(for: id) }
        } label: {
          Text("Use the Branch's Ticket", bundle: .module)
        }
      }
    }
  }
}

// MARK: - Page

/// Puts the tab's own web view on screen. The web view belongs to the tab: when this view goes,
/// the page waits in the parking window rather than being torn down.
private struct BrowserWebViewHost: NSViewRepresentable {
  let workspace: BrowserWorkspace
  let tab: BrowserTabModel
  let focusRequest: Int
  let isPageFocused: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(workspace: workspace)
  }

  func makeNSView(context: Context) -> BrowserWebViewContainer {
    let container = BrowserWebViewContainer()
    container.focusChanged = isPageFocused
    return container
  }

  func updateNSView(_ container: BrowserWebViewContainer, context: Context) {
    container.focusChanged = isPageFocused
    let webView = workspace.show(tab)
    if webView.superview !== container {
      for case let other as WKWebView in container.subviews where other !== webView {
        workspace.hide(other)
      }
      webView.removeFromSuperview()
      webView.frame = container.bounds
      webView.autoresizingMask = [.width, .height]
      container.addSubview(webView)
    }
    if context.coordinator.focusRequest != focusRequest {
      let isFirst = context.coordinator.focusRequest == nil
      context.coordinator.focusRequest = focusRequest
      if !isFirst { container.window?.makeFirstResponder(webView) }
    }
  }

  /// The panel went away — hidden, or the terminal took the room: its page waits in the parking
  /// window, where it keeps running and can still be captured, and the keyboard is no longer in it.
  static func dismantleNSView(_ container: BrowserWebViewContainer, coordinator: Coordinator) {
    MainActor.assumeIsolated {
      for case let webView as WKWebView in container.subviews {
        coordinator.workspace.hide(webView)
      }
      container.focusChanged?(false)
    }
  }

  @MainActor
  final class Coordinator {
    let workspace: BrowserWorkspace
    var focusRequest: Int?

    init(workspace: BrowserWorkspace) {
      self.workspace = workspace
    }
  }
}

/// The view pages are shown in. It tells the workspace when the keyboard enters or leaves a page,
/// so that ⌘W closes a tab rather than the session while a page has it.
final class BrowserWebViewContainer: NSView {
  var focusChanged: ((Bool) -> Void)?
  private var observation: NSKeyValueObservation?

  /// The page always fills the view: a page moved in from another panel, or from the parking
  /// window, keeps the size it had there otherwise.
  override func layout() {
    super.layout()
    for subview in subviews where subview.frame != bounds {
      subview.frame = bounds
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { focusChanged?(false) }
    observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let responder = window.firstResponder as? NSView
        self.focusChanged?(responder?.isDescendant(of: self) ?? false)
      }
    }
  }
}

private struct BrowserEmptyView: View {
  let model: AppModel
  @State private var text = ""
  @State private var isEditingTicket = false
  @State private var ticketText = ""

  var body: some View {
    BrowserStateView(
      symbol: "globe", tint: .secondary,
      title: Text("No page open", bundle: .module),
      message: Text(
        "Type an address above, or ⌘-click a link in the terminal.", bundle: .module)
    ) {
      VStack(spacing: 12) {
        Button {
          ticketText = ""
          isEditingTicket = true
        } label: {
          Text("Set Ticket…", bundle: .module)
        }
        Text(
          "The agent can open a page too, with its tab_open tool or `vibe browser open <url>`.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
      }
    }
    .alert(Text("Ticket", bundle: .module), isPresented: $isEditingTicket) {
      TextField(text: $ticketText) {
        Text("Ticket address or #number", bundle: .module)
      }
      Button {
        guard let id = model.selectedSessionID else { return }
        let value = ticketText
        Task { await model.setTicket(value, for: id) }
      } label: {
        Text("Set Ticket", bundle: .module)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: .module)
      }
    }
  }
}

private struct BrowserFailureView: View {
  let tab: BrowserTabModel
  let failure: BrowserLoadFailure

  var body: some View {
    switch failure {
    case .serverNotStarted(let origin):
      BrowserStateView(
        symbol: "terminal", tint: .secondary,
        title: Text("Nothing is listening on \(origin) yet", bundle: .module),
        message: tab.isRetrying
          ? Text(
            "The development server may still be starting. Retrying every 2 seconds — attempt \(tab.retryAttempt + 1).",
            bundle: .module)
          : Text("The development server may still be starting.", bundle: .module)
      ) {
        HStack {
          if tab.isRetrying {
            Button {
              tab.stopRetrying()
            } label: {
              Text("Stop Retrying", bundle: .module)
            }
          }
          Button {
            tab.reload()
          } label: {
            Text("Retry Now", bundle: .module)
          }
          .buttonStyle(.borderedProminent)
        }
      }
    case .offline(let host):
      unreachable(
        title: Text("Can’t reach \(host)", bundle: .module),
        message: Text("You appear to be offline.", bundle: .module))
    case .unreachable(let host, let reason):
      unreachable(
        title: Text("Can’t reach \(host)", bundle: .module), message: Text(verbatim: reason))
    case .insecure(let host, let isLocal):
      BrowserStateView(
        symbol: "lock.trianglebadge.exclamationmark", tint: .orange,
        title: Text("The certificate of \(host) is not trusted", bundle: .module),
        message: isLocal
          ? Text(
            "A development server often signs its own certificate. Continue only if it is yours.",
            bundle: .module)
          : Text("The page was not loaded.", bundle: .module)
      ) {
        if isLocal {
          Button {
            tab.acceptInsecureCertificate()
          } label: {
            Text("Continue Anyway", bundle: .module)
          }
        }
      }
    case .other(let reason):
      unreachable(
        title: Text("The page could not be loaded", bundle: .module),
        message: Text(verbatim: reason))
    }
  }

  private func unreachable(title: Text, message: Text) -> some View {
    BrowserStateView(
      symbol: "exclamationmark.triangle", tint: .orange, title: title, message: message
    ) {
      HStack {
        Button {
          tab.reload()
        } label: {
          Text("Try Again", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        Button {
          NSWorkspace.shared.open(tab.url)
        } label: {
          Text("Open in Browser", bundle: .module)
        }
      }
    }
  }
}

/// A symbol, a title, a sentence and what to do about it, in place of a page.
private struct BrowserStateView<Actions: View>: View {
  let symbol: String
  let tint: Color
  let title: Text
  let message: Text
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      title
        .font(.title3.weight(.semibold))
        .multilineTextAlignment(.center)
      message
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      actions
        .padding(.top, 4)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Agent

private struct BrowserPermissionBanner: View {
  let request: BrowserPermissionRequest
  let answer: (BrowserPermissionAnswer) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "sparkle")
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          question.font(.body.weight(.semibold))
          detail
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 8) {
        Spacer()
        Button {
          answer(.deny)
        } label: {
          Text("Deny", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        if request.grantKey != nil {
          Button {
            answer(.alwaysAllow)
          } label: {
            Text("Always Allow for \(request.site)", bundle: .module)
          }
        }
        Button {
          answer(.allowOnce)
        } label: {
          Text("Allow Once", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35))
    )
    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .onAppear {
      NSAccessibility.post(
        element: NSApp.mainWindow as Any, notification: .announcementRequested,
        userInfo: [
          .announcement: String(
            localized: "The agent is asking for your approval in the web view.", bundle: .module),
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
  }

  private var question: Text {
    switch request.kind {
    case .act(let tool, let target, _):
      switch tool {
      case "page_fill":
        return Text("The agent wants to type into \(target) on \(request.site).", bundle: .module)
      case "page_evaluate":
        return Text("The agent wants to run JavaScript on \(request.site).", bundle: .module)
      default:
        return Text("The agent wants to click \(target) on \(request.site).", bundle: .module)
      }
    case .effect(.download(let filename)):
      return Text("The agent’s action downloads “\(filename)”.", bundle: .module)
    case .effect(.externalApplication(let url)):
      return Text(
        "The agent’s action opens \(url.scheme ?? "") in another application.", bundle: .module)
    }
  }

  private var detail: Text {
    switch request.kind {
    case .act(_, _, let value?):
      return Text("Value: \(value)", bundle: .module)
        + Text(verbatim: " · ") + expiry
    case .act(let tool, let target, nil) where tool == "page_evaluate":
      return Text(verbatim: target + " · ") + expiry
    default:
      return expiry
    }
  }

  private var expiry: Text {
    Text(
      "Nothing is done unless you allow it; the request expires \(request.expiresAt, style: .relative).",
      bundle: .module)
  }
}

private struct BrowserTracePopover: View {
  let browser: SessionBrowser
  let clear: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Agent Actions", bundle: .module)
        .font(.headline)
        .padding(12)
      Divider()
      if browser.actionLog.records.isEmpty {
        Text("No agent has acted in this web view yet.", bundle: .module)
          .foregroundStyle(.secondary)
          .padding(16)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(browser.actionLog.records.reversed()) { record in
              BrowserTraceRow(record: record)
              Divider()
            }
          }
        }
        .frame(maxHeight: 360)
      }
      Divider()
      HStack {
        Text("Reads are grouped. Kept with the session.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: clear) {
          Text("Clear", bundle: .module)
        }
        .disabled(browser.actionLog.records.isEmpty)
      }
      .padding(10)
    }
    .frame(width: 460)
  }
}

private struct BrowserTraceRow: View {
  let record: BrowserActionRecord

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(record.date, format: .dateTime.hour().minute().second())
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 64, alignment: .leading)
      Text(verbatim: record.count > 1 ? "\(record.tool) ×\(record.count)" : record.tool)
        .font(.system(.callout, design: .monospaced))
        .frame(width: 120, alignment: .leading)
      Text(verbatim: [record.origin, record.target].filter { !$0.isEmpty }.joined(separator: " "))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      decision
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }

  private var tint: Color {
    switch record.decision {
    case .automatic, .always: return record.succeeded ? .green : .orange
    case .confirmed: return .accentColor
    case .denied, .expired: return .red
    }
  }

  private var decision: Text {
    guard record.succeeded || record.decision == .denied || record.decision == .expired else {
      return Text(
        "Failed", bundle: .module, comment: "An agent action in the web view that failed.")
    }
    switch record.decision {
    case .automatic:
      return Text("Auto", bundle: .module, comment: "An agent action that needed no approval.")
    case .always:
      return Text("Always", bundle: .module, comment: "An agent action allowed by Always Allow.")
    case .confirmed:
      return Text("Allowed", bundle: .module, comment: "An agent action the user allowed once.")
    case .denied:
      return Text("Denied", bundle: .module, comment: "An agent action the user refused.")
    case .expired:
      return Text("Expired", bundle: .module, comment: "An agent request nobody answered in time.")
    }
  }
}
