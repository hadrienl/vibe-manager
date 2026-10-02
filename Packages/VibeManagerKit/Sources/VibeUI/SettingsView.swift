import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeBrowser
import VibeConversationUI
import VibeDomain

/// The application's settings (#313): a sidebar of pages, as System Settings has, and the page
/// chosen beside it, in a window that keeps its size from one page to the next and widens only
/// for a page that needs the room.
///
/// Several lines are ways back to a question asked once. The Full Disk Access step at launch is
/// not asked again by the same identity, and neither is the close confirmation once "Don't ask
/// again" was ticked: refusing either must not be a door that closes, so this is where the user
/// finds the question again.
public struct SettingsView: View {
  private let permissions: PermissionsModel?
  private let model: AppModel?

  public init(permissions: PermissionsModel? = nil, model: AppModel? = nil) {
    self.permissions = permissions
    self.model = model
  }

  public var body: some View {
    if let model {
      SettingsSplitView(model: model, permissions: permissions)
        .environment(\.sessionAppearancePalette, model.appearancePalette.offered)
    } else {
      privacyOnly
    }
  }

  /// Without the workspace, the window is this one form.
  private var privacyOnly: some View {
    Form {
      Section {
        if let permissions {
          FullDiskAccessRow(permissions: permissions)
        } else {
          Text("File access cannot be read in this window.", bundle: .module)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Privacy", bundle: .module, comment: "A section of the Settings window.")
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: SettingsPage.standardDetailWidth)
    .task { await permissions?.recheck() }
  }
}

/// The sidebar and the page, with the way back from a page reached from another.
struct SettingsSplitView: View {
  @Bindable var model: AppModel
  let permissions: PermissionsModel?
  /// The page on screen. It follows the model's, through a slide when one page is reached from
  /// the other, as System Settings does.
  @State private var shown: SettingsPage?
  /// Where the page coming in slides from: the trailing edge going in, the leading edge back.
  @State private var arrival: Edge = .trailing
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  nonisolated static let sidebarWidth: CGFloat = 215
  nonisolated static let minimumHeight: CGFloat = 460
  nonisolated static let idealHeight: CGFloat = 700

  /// The window's width with a page that is a single form.
  nonisolated static var standardWidth: CGFloat {
    sidebarWidth + SettingsPage.standardDetailWidth
  }

  var body: some View {
    let sidebar = SettingsSidebarContent(model: model, permissions: permissions, locale: locale)
    let target = sidebar.shown(model.settingsPage)
    let page = shown.map(sidebar.shown) ?? target
    NavigationSplitView(columnVisibility: .constant(.all)) {
      SettingsSidebar(model: model, content: sidebar)
        .toolbar(removing: .sidebarToggle)
        // Both: the column's width alone is not kept by the split view of the settings window,
        // which gave the sidebar 144 points and cut the names of its pages.
        .frame(width: Self.sidebarWidth)
        .navigationSplitViewColumnWidth(Self.sidebarWidth)
    } detail: {
      GeometryReader { proxy in
        ZStack(alignment: .topLeading) {
          SettingsPageView(model: model, permissions: permissions, page: page)
            // Laid out at its own width at once: the window widening uncovers it, rather than
            // squeezing it the time it takes. Its least size stays out of the window's.
            .frame(
              width: max(proxy.size.width, page.detailWidth), height: proxy.size.height,
              alignment: .topLeading)
            .id(page)
            .transition(.push(from: arrival))
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        .clipped()
      }
      .navigationTitle(Text(sidebar.name(of: page)))
      .toolbar {
        // Always there, as in System Settings: the toolbar keeps its height from page to page.
        ToolbarItem(placement: .navigation) {
          Button {
            if let parent = page.parent { model.settingsPage = parent }
          } label: {
            Image(systemName: "chevron.left")
          }
          .disabled(page.parent == nil)
          .help(Text("Back", bundle: .module))
          .accessibilityLabel(Text("Back", bundle: .module))
        }
      }
    }
    .onChange(of: target) { old, new in
      let isGoingIn = new.parent == old
      guard isGoingIn || old.parent == new, !reduceMotion else {
        shown = new
        return
      }
      arrival = isGoingIn ? .trailing : .leading
      withAnimation(.smooth(duration: 0.3)) { shown = new }
    }
    .modifier(SettingsToolbarVeil())
    .frame(
      minWidth: Self.standardWidth, idealWidth: Self.standardWidth,
      minHeight: Self.minimumHeight, idealHeight: Self.idealHeight)
    .background(SettingsWindowSizer(width: Self.sidebarWidth + target.detailWidth))
  }
}

/// What scrolls under the toolbar is veiled the whole height of it: with the soft edge of
/// macOS 26, the words of a form stayed legible under the title.
private struct SettingsToolbarVeil: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.scrollEdgeEffectStyle(.hard, for: .top)
    } else {
      content
    }
  }
}

/// What the sidebar lists, in its groups: the pages this workspace has, each agent that can be
/// tracked and each endpoint.
@MainActor
struct SettingsSidebarContent {
  struct Entry: Identifiable {
    var page: SettingsPage
    /// The name shown: the page's, or the agent's or endpoint's own.
    var name: String
    var symbolName: String
    var tint: Color
    /// The dot after the name: an agent tracked or not, an endpoint's last test.
    var status: Color?
    var id: SettingsPage { page }
  }

  struct Group: Identifiable {
    var id: String
    var title: LocalizedStringResource?
    var entries: [Entry]
  }

  let groups: [Group]
  /// The language of the window, which names the pages.
  let locale: Locale

  init(model: AppModel, permissions: PermissionsModel?, locale: Locale = .current) {
    self.locale = locale
    func entry(_ page: SettingsPage) -> Entry {
      Entry(
        page: page, name: SettingsPage.string(page.title, locale: locale),
        symbolName: page.symbolName, tint: page.tint)
    }
    var groups = [
      Group(
        id: "application", title: nil,
        entries: [.general, .conversation, .sessionAppearance, .requests].map(entry))
    ]
    if !model.hookTrustingAgents.isEmpty {
      groups.append(
        Group(
          id: "agents",
          title: LocalizedStringResource(
            "Agents", bundle: .module, comment: "A group of the Settings window's sidebar."),
          entries: model.hookTrustingAgents.map { agent in
            Entry(
              page: .agent(agent.id), name: agent.displayName, symbolName: agent.symbolName,
              tint: SettingsPage.agent(agent.id).tint,
              status: model.reportsActivity[agent.id] ?? true
                ? .green : Color(nsColor: .tertiaryLabelColor))
          }))
    }
    if let endpoints = model.endpoints {
      let page = SettingsPage.newEndpoint
      groups.append(
        Group(
          id: "endpoints",
          title: LocalizedStringResource(
            "Endpoints", bundle: .module, comment: "A group of the Settings window's sidebar."),
          entries: endpoints.endpoints.map { endpoint in
            Entry(
              page: .endpoint(endpoint.id),
              name: endpoint.name.isEmpty ? " " : endpoint.name,
              symbolName: SettingsPage.endpoint(endpoint.id).symbolName,
              tint: SettingsPage.endpoint(endpoint.id).tint,
              status: EndpointsSettingsView.color(of: endpoint.lastTest?.verdict))
          } + [
            Entry(
              page: page,
              name: SettingsPage.string(
                LocalizedStringResource(
                  "Add an Endpoint…", bundle: .module,
                  comment: "The last line of the endpoints in the Settings window's sidebar."),
                locale: locale),
              symbolName: page.symbolName, tint: page.tint)
          ]))
    }
    var tools: [SettingsPage] = []
    if model.browser != nil { tools.append(.webView) }
    tools.append(.templates)
    if model.ticketTitles.canReadPages { tools.append(.tickets) }
    groups.append(
      Group(
        id: "tools",
        title: LocalizedStringResource(
          "Tools", bundle: .module, comment: "A group of the Settings window's sidebar."),
        entries: tools.map(entry)))
    var system: [SettingsPage] = []
    if permissions != nil || model.usage != nil || model.canExportDiagnostics {
      system.append(.privacy)
    }
    if model.updates != nil { system.append(.updates) }
    if !system.isEmpty {
      groups.append(Group(id: "system", title: nil, entries: system.map(entry)))
    }
    self.groups = groups
  }

  /// The page to show for `page`: itself when this workspace has it, General otherwise — an
  /// endpoint deleted, an agent gone.
  func shown(_ page: SettingsPage) -> SettingsPage {
    groups.contains { $0.entries.contains { $0.page == page.sidebarPage } } ? page : .general
  }

  /// The name of `page` in the window's title: the agent's or endpoint's for theirs.
  func name(of page: SettingsPage) -> String {
    // The new endpoint's line says what it does, "Add an Endpoint…"; its page is named.
    if page.parent == nil, page != .newEndpoint,
      let entry = groups.lazy.flatMap(\.entries).first(where: { $0.page == page })
    {
      return entry.name
    }
    return SettingsPage.string(page.title, locale: locale)
  }
}

/// The list of the pages, grouped.
private struct SettingsSidebar: View {
  @Bindable var model: AppModel
  let content: SettingsSidebarContent

  var body: some View {
    let groups = content.groups
    List(
      selection: Binding(
        get: { Optional(model.settingsPage.sidebarPage) },
        set: { page in
          if let page, page != model.settingsPage.sidebarPage { model.settingsPage = page }
        })
    ) {
      ForEach(groups) { group in
        Section {
          if group.id == "endpoints" {
            ForEach(group.entries.filter { $0.page != .newEndpoint }) { entry in
              row(entry)
            }
            .onMove { source, destination in
              guard let endpoints = model.endpoints else { return }
              var list = endpoints.endpoints
              list.move(fromOffsets: source, toOffset: destination)
              Task { await endpoints.save(list) }
            }
            ForEach(group.entries.filter { $0.page == .newEndpoint }) { entry in
              row(entry)
            }
          } else {
            ForEach(group.entries) { entry in
              row(entry)
            }
          }
        } header: {
          if let title = group.title {
            Text(title)
          }
        }
      }
    }
    .listStyle(.sidebar)
    // The endpoints are read from their file the first time the window shows them.
    .task { await model.endpoints?.load() }
  }

  private func row(_ entry: SettingsSidebarContent.Entry) -> some View {
    Label {
      HStack(spacing: 6) {
        Text(verbatim: entry.name)
        Spacer(minLength: 0)
        if let status = entry.status {
          Circle()
            .fill(status)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
        }
      }
    } icon: {
      SettingsPageIcon(symbolName: entry.symbolName, tint: entry.tint)
    }
    .tag(Optional(entry.page))
  }
}

/// The page shown beside the sidebar.
struct SettingsPageView: View {
  @Bindable var model: AppModel
  let permissions: PermissionsModel?
  let page: SettingsPage

  var body: some View {
    switch page {
    case .general:
      GeneralSettingsPage(model: model)
    case .conversation:
      ConversationSettingsView(
        appearance: Bindable(model.conversations).appearance,
        themes: model.conversations.themes)
    case .sessionAppearance:
      SessionAppearanceSettingsView(model: model.appearancePalette)
    case .requests:
      SignallingSettings(model: model)
        // Each time the page appears: the avatars made or deleted meanwhile.
        .task { await model.avatars?.refresh() }
    case .avatars:
      if let avatars = model.avatars {
        AvatarLibraryView(avatars: avatars)
          .task { await avatars.refresh() }
      }
    case .agent(let id):
      if let agent = model.hookTrustingAgents.first(where: { $0.id == id }) {
        AgentSettingsPage(model: model, agent: agent)
      }
    case .endpoint(let id):
      if let endpoints = model.endpoints {
        EndpointsSettingsView(model: endpoints, endpointID: id) { model.settingsPage = $0 }
          .id(page)
      }
    case .newEndpoint:
      if let endpoints = model.endpoints {
        EndpointsSettingsView(model: endpoints, endpointID: nil) { model.settingsPage = $0 }
          .id(page)
      }
    case .webView:
      if let browser = model.browser {
        WebViewSettings(browser: browser)
      }
    case .templates:
      PromptTemplatesView(
        model: model.templates, themes: model.conversations.themes,
        conversationAppearance: model.conversations.appearance)
    case .tickets:
      TicketSettingsView(model: model.ticketTitles, pane: .general) { model.settingsPage = $0 }
    case .ticketResolvers:
      TicketSettingsView(model: model.ticketTitles, pane: .resolvers) { model.settingsPage = $0 }
    case .privacy:
      PrivacySettingsView(permissions: permissions, model: model)
    case .updates:
      if let updates = model.updates {
        UpdatesSettingsView(updates: updates)
      }
    }
  }
}

/// Settings › General: the sessions, their summary, their side terminals, and where a changed
/// file opens.
struct GeneralSettingsPage: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section {
        OpenSessionsInRow(appearance: Bindable(model.conversations).appearance)
        SessionCloseRow(model: model)
        QuitBehaviorRow(model: model)
      } header: {
        Text("Sessions", bundle: .module, comment: "A section of the Settings window.")
      }
      if let journal = model.journal {
        Section {
          SummaryRow(journal: journal)
        } header: {
          Text("Summary", bundle: .module, comment: "The heading of a session's summary.")
        }
      }
      if let terminals = model.terminals {
        Section {
          SideTerminalsRow(terminals: terminals)
        } header: {
          Text("Side Terminals", bundle: .module, comment: "A section of the Settings window.")
        }
      }
      Section {
        EditorRow(model: model)
      } header: {
        Text("Changed Files", bundle: .module, comment: "A section of the Settings window.")
      }
    }
    .formStyle(.grouped)
  }
}

/// Whether a new session shows its conversation or its terminal (#38).
private struct OpenSessionsInRow: View {
  @Binding var appearance: ConversationAppearance

  var body: some View {
    Picker(selection: $appearance.defaultPresentation) {
      Text("Conversation", bundle: .module).tag(SessionPresentation.conversation)
      Text("Terminal", bundle: .module).tag(SessionPresentation.terminal)
    } label: {
      Text("Open sessions in", bundle: .module)
      Text("Each session can then be switched with ⌥⌘T, and keeps its choice.", bundle: .module)
    }
    .pickerStyle(.segmented)
  }
}

/// Settings › an agent: whether its activity is tracked (#45).
struct AgentSettingsPage: View {
  let model: AppModel
  let agent: AgentDescriptor

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          Image(systemName: agent.symbolName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPage.agent(agent.id).tint.gradient)
            )
            .accessibilityHidden(true)
          Text(verbatim: agent.displayName)
            .font(.title3.weight(.semibold))
        }
        .padding(.vertical, 4)
      }
      Section {
        AgentActivityRow(model: model, agent: agent)
      } header: {
        Text("Activity", bundle: .module, comment: "A section of an agent's page of the Settings.")
      }
    }
    .formStyle(.grouped)
  }
}

/// Full Disk Access, and whether it has reached the agents yet; then what the application keeps
/// on this Mac: the usage it records, and the diagnostics it can export.
///
/// Asks a process born now each time the page is opened: whoever opens it has usually just been
/// to System Settings, and this window — launched before — could only repeat what it got then.
struct PrivacySettingsView: View {
  let permissions: PermissionsModel?
  let model: AppModel

  var body: some View {
    Form {
      if let permissions {
        Section {
          FullDiskAccessRow(permissions: permissions)
        } header: {
          Text("Full Disk Access", bundle: .module, comment: "A section of the Settings window.")
        } footer: {
          FullDiskAccessSheet.reach
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let report = permissions.report, !report.isConsistent {
          Section {
            ProcessAccessRows(report: report)
          } header: {
            Text(
              "Process by Process", bundle: .module, comment: "A section of the Settings window.")
          } footer: {
            Text(
              """
              macOS gives each process the access it had when it started. Agents run in a \
              background process of Vibe Manager, which keeps running while they work.
              """,
              bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      if model.usage != nil || model.canExportDiagnostics {
        Section {
          if let usage = model.usage {
            UsageSettingsRow(usage: usage)
          }
          if model.canExportDiagnostics {
            LabeledContent {
              Button {
                model.beginDiagnosticsExport()
              } label: {
                Text("Export Diagnostics…", bundle: .module)
              }
            } label: {
              Text("Diagnostics", bundle: .module)
              Text(
                """
                A local log of what the application did, never of what you typed, kept for two \
                weeks. Exported only when you save it yourself.
                """,
                bundle: .module
              )
            }
          }
        } header: {
          Text(
            "Data on This Mac", bundle: .module,
            comment: "A section of Settings › Privacy: the usage and the diagnostics.")
        }
      }
    }
    .formStyle(.grouped)
    .restartNowConfirmation(
      permissions: permissions, origin: .settings, sessionName: model.sessionName(for:))
    .task { await permissions?.recheck() }
  }
}

/// Widens the settings window to what the page shown needs, and brings it back to its width once
/// the page is left (#313).
///
/// The window is the user's to size otherwise: it is only widened, never narrowed below what the
/// user gave it, and it moves left rather than leave the screen.
struct SettingsWindowSizer: NSViewRepresentable {
  /// The width the window needs for the page shown.
  let width: CGFloat

  func makeNSView(context: Context) -> SizerView { SizerView() }

  func updateNSView(_ view: SizerView, context: Context) {
    view.neededWidth = width
  }

  final class SizerView: NSView {
    /// The width the window had before a page widened it, given back when the page is left.
    private var restoredWidth: CGFloat?
    /// The width this view gave the window last. Another width is the user's, which is kept.
    private var givenWidth: CGFloat?

    var neededWidth: CGFloat = 0 {
      didSet {
        guard neededWidth != oldValue else { return }
        resize(animated: window?.isVisible == true)
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      resize(animated: false)
    }

    private func resize(animated: Bool) {
      guard let window, neededWidth > 0, !window.styleMask.contains(.fullScreen) else { return }
      // Resized by hand since: the user's width is the one to come back to no more.
      if let givenWidth, abs(window.frame.width - givenWidth) > 0.5 { restoredWidth = nil }
      let screen = window.screen?.visibleFrame
      // Never narrower than the page shown: a page squeezed below its width is cut (#152). The
      // content's least size, which the least height SwiftUI gave stays part of.
      window.contentMinSize = NSSize(
        width: min(neededWidth, screen?.width ?? neededWidth),
        height: max(window.contentMinSize.height, SettingsSplitView.minimumHeight))
      guard
        let plan = SettingsWindowWidth.plan(
          frame: window.frame, needed: neededWidth, restoredWidth: restoredWidth, screen: screen)
      else { return }
      restoredWidth = plan.restoredWidth
      givenWidth = plan.frame.width
      // AppKit's own resizing, as the tabs of a preferences window had: SwiftUI, which sizes
      // the settings window too, let the animator's frame go.
      window.setFrame(
        plan.frame, display: true,
        animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
  }
}

/// The frame the settings window takes for a page, and the width to give back after it.
enum SettingsWindowWidth {
  struct Plan: Equatable {
    var frame: NSRect
    var restoredWidth: CGFloat?
  }

  /// `nil` when the window keeps its frame.
  ///
  /// Wider than the window, the page widens it, and the width it had is kept to be given back.
  /// Narrower, the window goes back to that width, or to what the page needs if it is between.
  static func plan(frame: NSRect, needed: CGFloat, restoredWidth: CGFloat?, screen: NSRect?)
    -> Plan?
  {
    var restored = restoredWidth
    var width = frame.width
    if needed > frame.width {
      restored = restored ?? frame.width
      width = needed
    } else if let previous = restoredWidth {
      width = max(previous, needed)
      if width <= previous { restored = nil }
    }
    var target = frame
    target.size.width = width
    if let screen {
      target.size.width = min(target.width, screen.width)
      // Grown to the right, as System Settings does, unless the screen ends first.
      if target.maxX > screen.maxX {
        target.origin.x = max(screen.minX, screen.maxX - target.width)
      }
    }
    guard target != frame else {
      return restored == restoredWidth ? nil : Plan(frame: frame, restoredWidth: restored)
    }
    return Plan(frame: target, restoredWidth: restored)
  }
}

/// The access as the agents get it, and what to do about it.
private struct FullDiskAccessRow: View {
  let permissions: PermissionsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent {
        Label {
          Text(label)
        } icon: {
          Image(systemName: symbolName)
        }
        .foregroundStyle(permissions.situation == .granted ? .secondary : .primary)
      } label: {
        Text("Full Disk Access", bundle: .module)
      }

      switch permissions.situation {
      case .notGranted:
        Text(
          """
          Without it, macOS asks for permission each time an agent reads your Desktop, Documents, \
          Downloads, an external disk or iCloud Drive.
          """,
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      case .pendingRestart(let runner, let running):
        PendingRestartExplanation(runner: runner, runningAgents: running)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .granted, .checking:
        EmptyView()
      }

      // In every state, checking included: to grant the access, and to take it back. On the row of
      // the restart buttons when there are some, rather than on a row of its own under them.
      if offersRestart {
        RestartHostButtons(permissions: permissions, origin: .settings) {
          openSystemSettingsButton
        }
      } else {
        openSystemSettingsButton
      }
    }
  }

  private var offersRestart: Bool {
    guard case .pendingRestart(let runner, let running) = permissions.situation else {
      return false
    }
    return runner == .host && running > 0
  }

  private var openSystemSettingsButton: some View {
    Button {
      permissions.openSystemSettings()
    } label: {
      Text("Open System Settings", bundle: .module)
    }
  }

  private var label: LocalizedStringResource {
    switch permissions.situation {
    case .granted:
      return LocalizedStringResource(
        "Granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .notGranted:
      return LocalizedStringResource(
        "Not granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .pendingRestart:
      return LocalizedStringResource(
        "Granted, not yet in effect", bundle: .module,
        comment: "The state of Full Disk Access: granted, but the agents do not have it yet.")
    case .checking:
      return LocalizedStringResource(
        "Checking…", bundle: .module, comment: "The state of Full Disk Access.")
    }
  }

  private var symbolName: String {
    switch permissions.situation {
    case .granted: return "checkmark.circle"
    case .notGranted: return "exclamationmark.circle"
    case .pendingRestart: return "arrow.clockwise.circle"
    case .checking: return "clock"
    }
  }
}

/// Why the access granted has not reached the agents, in one or two sentences.
struct PendingRestartExplanation: View {
  let runner: FullDiskAccessSituation.PendingRunner
  let runningAgents: Int

  var body: some View {
    switch runner {
    case .application:
      Text(
        "Agents run inside Vibe Manager for now. Quit and reopen Vibe Manager to give them the access.",
        bundle: .module)
    case .host:
      if runningAgents == 0 {
        Text(
          "The background process that runs agents is restarting to take the access.",
          bundle: .module)
      } else {
        Text(
          """
          The \(runningAgents) agents running now were started before the access was granted. \
          They get it once the background process that runs them restarts.
          """,
          bundle: .module,
          comment: "The number of agents running without Full Disk Access.")
      }
    }
  }
}

/// Restart the host when the last agent ends, or now — the one road that stops agents, and only
/// once they have been named. `trailing` ends the same row: another action of the same place.
struct RestartHostButtons<Trailing: View>: View {
  let permissions: PermissionsModel
  let origin: RestartNowRequest.Origin
  @ViewBuilder let trailing: () -> Trailing

  init(
    permissions: PermissionsModel, origin: RestartNowRequest.Origin,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.permissions = permissions
    self.origin = origin
    self.trailing = trailing
  }

  var body: some View {
    HStack {
      if permissions.isRestartArmed {
        Label {
          Text("Restarts when the last running agent ends.", bundle: .module)
        } icon: {
          Image(systemName: "clock.arrow.circlepath")
        }
        .font(.callout)
        Button {
          Task { await permissions.cancelRestartWhenIdle() }
        } label: {
          Text("Don't Restart", bundle: .module)
        }
      } else {
        Button {
          Task { await permissions.restartWhenIdle() }
        } label: {
          Text("Restart When Idle", bundle: .module)
        }
      }
      Button {
        Task { await permissions.beginRestartNow(from: origin) }
      } label: {
        Text("Restart Now…", bundle: .module)
      }
      .disabled(!permissions.canRestartNow)
      trailing()
    }
  }
}

extension RestartHostButtons where Trailing == EmptyView {
  init(permissions: PermissionsModel, origin: RestartNowRequest.Origin) {
    self.init(permissions: permissions, origin: origin) { EmptyView() }
  }
}

/// What each process got, when they disagree.
private struct ProcessAccessRows: View {
  let report: FullDiskAccessReport

  var body: some View {
    LabeledContent {
      Text(state(report.identity))
    } label: {
      Text("Vibe Manager", bundle: .module)
      Text("What a process of this copy gets when it starts now.", bundle: .module)
    }
    if report.runner.runner == .host {
      LabeledContent {
        Text(state(report.runner.hostStatus))
      } label: {
        Text("Background process that runs agents", bundle: .module)
        Text(
          "\(report.runner.runningAgents) agents running", bundle: .module,
          comment: "The number of agents running in the background process.")
      }
    }
    LabeledContent {
      Text(state(report.interface))
    } label: {
      Text("This window", bundle: .module)
      Text("Until Vibe Manager is next opened.", bundle: .module)
    }
  }

  private func state(_ status: FullDiskAccessStatus?) -> LocalizedStringResource {
    switch status {
    case .granted:
      return LocalizedStringResource(
        "Granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .notGranted:
      return LocalizedStringResource(
        "Not granted", bundle: .module, comment: "The state of Full Disk Access.")
    case nil:
      return LocalizedStringResource(
        "Unknown", bundle: .module,
        comment: "The state of Full Disk Access of a process that cannot say.")
    }
  }
}

extension View {
  /// Asks before "Restart Now" stops the agents it names.
  func restartNowConfirmation(
    permissions: PermissionsModel, origin: RestartNowRequest.Origin,
    sessionName: @escaping (SessionID) -> String
  ) -> some View {
    modifier(
      RestartNowConfirmation(permissions: permissions, origin: origin, sessionName: sessionName))
  }

  /// The same, for a workspace that may have no permissions to speak of.
  @ViewBuilder
  func restartNowConfirmation(
    permissions: PermissionsModel?, origin: RestartNowRequest.Origin,
    sessionName: @escaping (SessionID) -> String
  ) -> some View {
    if let permissions {
      restartNowConfirmation(permissions: permissions, origin: origin, sessionName: sessionName)
    } else {
      self
    }
  }
}

/// Put only in the window that asked, with the sessions it named: the button carries them, so the
/// alert closing — which clears the request — cannot lose them on the way.
private struct RestartNowConfirmation: ViewModifier {
  let permissions: PermissionsModel
  let origin: RestartNowRequest.Origin
  let sessionName: (SessionID) -> String

  private var request: RestartNowRequest? {
    permissions.pendingRestartNow.flatMap { $0.origin == origin ? $0 : nil }
  }

  func body(content: Content) -> some View {
    content.alert(
      Text("Restart the running agents?", bundle: .module),
      isPresented: Binding(
        get: { request != nil },
        set: { if !$0, request != nil { permissions.cancelRestartNow() } }),
      presenting: request
    ) { request in
      Button(role: .destructive) {
        Task { await permissions.confirmRestartNow(request) }
      } label: {
        Text("Restart Now", bundle: .module)
      }
      Button(role: .cancel) {
        permissions.cancelRestartNow()
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: { request in
      Text(
        """
        \(request.sessions.map(sessionName).formatted(.list(type: .and))) will stop, then resume their \
        conversation with Full Disk Access. What an agent is doing right now is interrupted.
        """,
        bundle: .module,
        comment: "The names of the sessions whose agent is restarted, as a list.")
    }
  }
}

/// Whether an agent whose CLI approves its hooks reports its activity (#45). Turned back on, the
/// next launch of that agent asks again.
private struct AgentActivityRow: View {
  let model: AppModel
  let agent: AgentDescriptor

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { model.reportsActivity[agent.id] ?? true },
        set: { model.setReportsActivity($0, for: agent.id) })
    ) {
      Text(
        "Track \(agent.displayName) activity", bundle: .module,
        comment: "A setting; the argument is the agent's name.")
      Text(
        "Shows in the sidebar when it works, asks a question or has finished. Needs hooks \(agent.displayName) asks you to approve once.",
        bundle: .module,
        comment:
          "Under the setting that tracks an agent's activity; the argument is the agent's name.")
    }
  }
}

/// Whether each session's drawer of side terminals (#43) keeps what it showed.
private struct SideTerminalsRow: View {
  let terminals: SessionTerminals

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { terminals.keepsScrollback },
        set: { keeps in Task { await terminals.setKeepsScrollback(keeps) } })
    ) {
      Text("Keep the history of side terminals", bundle: .module)
      Text(
        """
        What each side terminal showed is written to disk, so that it is still there when its \
        session is reopened or Vibe Manager relaunched. It stays on this Mac, readable by you \
        alone and out of backups. Turned off, the histories already kept are erased.
        """,
        bundle: .module)
    }
  }
}

/// Whether each session's agent writes the summary of what it did (#36).
private struct SummaryRow: View {
  @Bindable var journal: SessionJournalModel

  var body: some View {
    Toggle(isOn: $journal.summariesEnabled) {
      Text("Summarize sessions automatically", bundle: .module)
      Text(
        """
        After each turn, the session's agent writes a short summary of what it did, with the same \
        account, the lightest model it offers and at most one summary every five minutes. The \
        tickets, requests, branches and worktrees used are listed either way.
        """,
        bundle: .module)
    }
  }
}

private struct SessionCloseRow: View {
  @Bindable var model: AppModel

  var body: some View {
    Toggle(isOn: $model.confirmsStoppingRunningAgent) {
      // Closing and archiving (#115) share it: both stop what runs.
      Text("Ask before closing or archiving a session where work is running", bundle: .module)
    }
  }
}

/// The question asked when quitting with agents running, and the way back to it once
/// "Don't ask again" was ticked.
private struct QuitBehaviorRow: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(selection: $model.quitBehavior) {
        Text("Ask", bundle: .module, comment: "What to do when quitting with agents running.")
          .tag(QuitBehavior.ask)
        Text(
          "Keep them running", bundle: .module,
          comment: "What to do when quitting with agents running."
        )
        .tag(QuitBehavior.keepRunning)
        Text("Stop them", bundle: .module, comment: "What to do when quitting with agents running.")
          .tag(QuitBehavior.stopAll)
      } label: {
        Text("When quitting with agents running", bundle: .module)
      }
      Text(
        """
        Agents kept running go on working in the background, and are back on screen as they are \
        the next time Vibe Manager is opened. A restart of the Mac stops them.
        """,
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Where a changed file of the inspector opens. Without a choice it is only revealed: nothing is
/// opened in an application the user did not pick.
private struct EditorRow: View {
  @Bindable var model: AppModel
  /// Renewed when "Other…" is cancelled: the setting did not change, so nothing else would bring
  /// the popup back from "Other…" to the choice that holds.
  @State private var pickerIdentity = 0

  private enum Choice: Hashable {
    case revealOnly
    case defaultApplication
    case application(String)
    case other
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(selection: selection) {
        Text("Finder (reveal only)", bundle: .module).tag(Choice.revealOnly)
        Text("Default Application", bundle: .module).tag(Choice.defaultApplication)
        let editors = model.gitInspector.installedEditors()
        if !editors.isEmpty || chosenElsewhere != nil {
          Divider()
        }
        ForEach(editors, id: \.bundleIdentifier) { editor in
          Text(editor.name).tag(Choice.application(editor.bundleIdentifier))
        }
        if let chosenElsewhere {
          Text(chosenElsewhere.name).tag(Choice.application(chosenElsewhere.identifier))
        }
        Divider()
        Text("Other…", bundle: .module, comment: "Picks another application to open files with.")
          .tag(Choice.other)
      } label: {
        Text("Open changed files with", bundle: .module)
      }
      .id(pickerIdentity)
      if case .application = model.fileEditor, let editor = model.fileEditor,
        model.gitInspector.name(of: editor) == nil
      {
        Text(
          "This editor is no longer installed: files are revealed in the Finder instead.",
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Text("Double-click a file in the Git list, or press Return, to open it.", bundle: .module)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The chosen application when the installed editors do not list it: picked with "Other…", or
  /// a known editor uninstalled since. Without it the picker would show no choice at all.
  private var chosenElsewhere: (identifier: String, name: String)? {
    guard case .application(let identifier) = model.fileEditor,
      !model.gitInspector.installedEditors().contains(where: { $0.bundleIdentifier == identifier })
    else { return nil }
    return (
      identifier,
      model.gitInspector.name(of: .application(bundleIdentifier: identifier)) ?? identifier
    )
  }

  private var selection: Binding<Choice> {
    Binding(
      get: {
        switch model.fileEditor {
        case nil: return .revealOnly
        case .defaultApplication: return .defaultApplication
        case .application(let identifier): return .application(identifier)
        }
      },
      set: { choice in
        switch choice {
        case .revealOnly: model.fileEditor = nil
        case .defaultApplication: model.fileEditor = .defaultApplication
        case .application(let identifier):
          model.fileEditor = .application(bundleIdentifier: identifier)
        case .other: chooseApplication()
        }
      }
    )
  }

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.application]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(
      localized: "Choose", bundle: .module,
      comment: "The button of the panel that picks an application to open files with.")
    guard panel.runModal() == .OK, let url = panel.url,
      let identifier = Bundle(url: url)?.bundleIdentifier
    else {
      pickerIdentity += 1
      return
    }
    model.fileEditor = .application(bundleIdentifier: identifier)
  }
}

/// Turning usage tracking off, and forgetting what it recorded.
///
/// Off, nothing is written and no transcript is read for usage; what was recorded stays visible.
/// Clearing deletes what the application recorded, never the agents' own transcripts.
private struct UsageSettingsRow: View {
  let usage: UsageModel
  @State private var isConfirmingClear = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { usage.isTrackingEnabled },
          set: { enabled in Task { await usage.setTracking(enabled) } }
        )
      ) {
        Text("Track agent usage", bundle: .module)
      }
      Text(
        """
        Running time, runs and the tokens your agents' transcripts report, kept on this Mac only. \
        Nothing is sent anywhere, and what the agents were asked or answered is never read.
        """,
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        isConfirmingClear = true
      } label: {
        Text("Clear Usage Data…", bundle: .module)
      }
      .confirmationDialog(
        Text("Clear usage data?", bundle: .module), isPresented: $isConfirmingClear
      ) {
        Button(role: .destructive) {
          Task { await usage.clear() }
        } label: {
          Text("Clear Usage Data", bundle: .module)
        }
      } message: {
        Text(
          """
          Running times, runs and token totals recorded on this Mac will be deleted. Your \
          agents' own transcripts are not touched.
          """,
          bundle: .module
        )
      }
    }
  }
}

/// Settings › Web View (#69). The preferences are read once and written as they
/// change: they live in the user defaults, which the view does not observe.
private struct WebViewSettings: View {
  let browser: BrowserWorkspace
  @State private var givesAgents = true
  @State private var showsOnAgentPage = true
  @State private var links: LinkDestination = .webView
  @State private var isConfirmingClear = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $givesAgents) {
          Text("Give agents the web view", bundle: .module)
          Text("From the next start of an agent.", bundle: .module)
        }
        .onChange(of: givesAgents) { _, value in browser.preferences.givesAgentsWebView = value }
        Toggle(isOn: $showsOnAgentPage) {
          Text("Show the web view when an agent opens a page", bundle: .module)
        }
        .onChange(of: showsOnAgentPage) { _, value in
          browser.preferences.showsWebViewWhenAgentOpensPage = value
        }
        Picker(selection: $links) {
          Text("In the web view", bundle: .module).tag(LinkDestination.webView)
          Text("In the default browser", bundle: .module)
            .tag(LinkDestination.defaultBrowser)
        } label: {
          Text("Open links", bundle: .module)
          Text(
            "Of the terminal, the conversation, the activity and the notes. ⌥-click opens the other way.",
            bundle: .module)
        }
        .onChange(of: links) { _, value in browser.preferences.links = value }
      }
      Section {
        if browser.grants.isEmpty {
          Text("None", bundle: .module, comment: "No site is always allowed.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(browser.grants.sorted(), id: \.self) { site in
            LabeledContent {
              Button {
                browser.revokeGrant(site)
              } label: {
                Text("Remove", bundle: .module)
              }
            } label: {
              Text(verbatim: site)
            }
          }
        }
      } header: {
        Text("Always allowed sites", bundle: .module)
      } footer: {
        Text(
          "Elsewhere than this Mac, an agent asks before clicking, typing or running JavaScript.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent {
          Button {
            isConfirmingClear = true
          } label: {
            Text("Clear…", bundle: .module, comment: "Clears the web view's browsing data.")
          }
        } label: {
          Text("Browsing data", bundle: .module)
          Text("Shared by every session, apart from Safari.", bundle: .module)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      givesAgents = browser.preferences.givesAgentsWebView
      showsOnAgentPage = browser.preferences.showsWebViewWhenAgentOpensPage
      links = browser.preferences.links
    }
    .confirmationDialog(
      Text("Clear the web view’s browsing data?", bundle: .module),
      isPresented: $isConfirmingClear
    ) {
      Button(role: .destructive) {
        Task { await browser.configuration.clearBrowsingData() }
      } label: {
        Text("Clear", bundle: .module)
      }
    } message: {
      Text(
        "You will be signed out of every site in every session’s web view.", bundle: .module)
    }
  }
}
