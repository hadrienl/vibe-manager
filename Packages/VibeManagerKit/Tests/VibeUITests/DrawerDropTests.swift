import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

/// Keeps what has no lasting file of its own, as the session's drop folder would.
private actor KeepingDropStore: SessionDropStore {
  private(set) var kept: [(name: String, id: SessionID)] = []

  func save(_ data: Data, suggestedName: String, for id: SessionID) -> URL {
    kept.append((suggestedName, id))
    return URL(fileURLWithPath: "/Drops/\(id.rawValue.uuidString)/\(suggestedName)")
  }

  func copy(_ file: URL, suggestedName: String, for id: SessionID) -> URL {
    kept.append((suggestedName, id))
    return URL(fileURLWithPath: "/Drops/\(id.rawValue.uuidString)/\(suggestedName)")
  }

  func remove(_ id: SessionID) {}

  func sweep(keeping ids: Set<SessionID>) {}
}

@Suite("Where a drop on a side terminal goes (#139)")
struct SideTerminalDropRouteTests {
  @Test("A side terminal takes a drop while its shell runs, whatever the agent does")
  func route() {
    #expect(
      SessionDropRoute.decideSideTerminal(isArchived: false, isShellRunning: true)
        == .terminal(fallback: false))
    #expect(
      SessionDropRoute.decideSideTerminal(isArchived: false, isShellRunning: false)
        == .refused(.shellNotRunning))
    #expect(
      SessionDropRoute.decideSideTerminal(isArchived: true, isShellRunning: true)
        == .refused(.archived))
  }

  @Test("A tab of the drawer dragged along its bar is not text to type")
  @MainActor
  func drawerTab() async {
    let id = TerminalID()
    let tab = DrawerTabDrag.text(for: id)
    #expect(DrawerTabDrag.terminalID(in: tab) == id)
    #expect(DrawerTabDrag.terminalID(in: id.rawValue.uuidString) == nil)
    let (items, failed) = await DropReader.read([NSItemProvider(object: tab as NSString)])
    #expect(items.isEmpty)
    #expect(failed == 0)
  }
}

/// A Finder drag let go over the drawer of side terminals, in a real window: the drawer's own view,
/// a real pasteboard, and the terminal host's doubles to read what each terminal was typed.
@MainActor
@Suite("Dropping files on the drawer of side terminals (#139)")
struct DrawerDropTests {
  private static let provider = WorkspaceProvider()
  private static let size = NSSize(width: 600, height: 300)

  private struct Fixture {
    let model: AppModel
    let supervisor: WorkspaceSupervisor
    let store: KeepingDropStore
    let session: WorkSession
    let drawer: SessionTerminalDrawer
    let folder: URL
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// A running session, its drawer shown with `tabs` running shells, and a file to drop.
  private func running(tabs: Int = 1) async throws -> Fixture {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("DrawerDropTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Drops",
      initialPrompt: "Look at these.",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: folder.path)]
    )
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let path = folder.path
    let terminals = SessionTerminals(
      supervisor: supervisor, viewportTimeout: .milliseconds(1), sessionFolder: { _ in path })
    let store = KeepingDropStore()
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, terminals: terminals,
      dropStore: store)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: session, plan: plan)
    await model.reload()
    model.select(session.id)
    await waitUntil { model.pane(for: session.id)?.status == .running }
    let drawer = terminals.drawer(for: session.id)
    await drawer.show()
    for _ in 1..<tabs { await drawer.newTerminal() }
    await waitUntil {
      drawer.terminals.count == tabs && drawer.terminals.allSatisfy { $0.pane.status == .running }
    }
    return Fixture(
      model: model, supervisor: supervisor, store: store, session: session, drawer: drawer,
      folder: folder)
  }

  private func typed(_ supervisor: WorkspaceSupervisor, _ id: TerminalID) async -> [String] {
    guard let terminal = await supervisor.session(for: id) as? WorkspaceTerminal else {
      return []
    }
    return await terminal.written.map { String(decoding: $0, as: UTF8.self) }
  }

  /// Lets `objects` go at `location` of the drawer's window — the origin at the bottom left, the
  /// bar of tabs along the top — and says whether the drawer took them. The pasteboard, which the
  /// drop reads after it was let go, is kept until `delivered` holds.
  private func drop(
    _ objects: [any NSPasteboardWriting], at location: NSPoint, on fixture: Fixture,
    until delivered: () async -> Bool = { true }
  ) async throws -> Bool {
    let host = NSHostingView(
      rootView: TerminalDrawerView(
        model: fixture.model, drawer: fixture.drawer, sessionName: fixture.session.name
      )
      .frame(width: Self.size.width, height: Self.size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    let pasteboard = NSPasteboard(name: .init("DrawerDropTests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(objects)
    guard let destination = Self.dropDestination(in: host) else { return false }
    let drag = PasteboardDrag(pasteboard: pasteboard, location: location, window: window)
    _ = destination.draggingEntered(drag)
    _ = destination.draggingUpdated(drag)
    _ = destination.prepareForDragOperation(drag)
    let taken = destination.performDragOperation(drag)
    if taken { await waitUntil(delivered) }
    return taken
  }

  private static func dropDestination(in view: NSView) -> NSView? {
    if !view.registeredDraggedTypes.isEmpty { return view }
    return view.subviews.lazy.compactMap(dropDestination(in:)).first
  }

  /// In the terminal, under the bar of tabs.
  private static let terminalPoint = NSPoint(x: 300, y: 120)
  /// On the first tab, near its left edge.
  private static let firstTabPoint = NSPoint(x: 16, y: size.height - 14)

  private func file(named name: String, in fixture: Fixture) throws -> URL {
    let url = fixture.folder.appendingPathComponent(name)
    try Data("a\n".utf8).write(to: url)
    return url
  }

  @Test("A file dropped on the terminal in front is typed into it, and not into the agent's")
  func terminalInFront() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let side = try #require(fixture.drawer.activeTerminal)
    let url = try file(named: "avec espace l'apostrophe.txt", in: fixture)

    #expect(
      try await drop([url as NSURL], at: Self.terminalPoint, on: fixture) {
        await !typed(fixture.supervisor, side.id).isEmpty
      })

    // A file of the temporary folder is kept in the session's drop folder, as #42 does.
    let kept =
      "/Drops/\(fixture.session.id.rawValue.uuidString)/avec\\ espace\\ l\\'apostrophe.txt "
    #expect(await typed(fixture.supervisor, side.id) == [kept])
    #expect(await fixture.store.kept.map(\.id) == [fixture.session.id])
    #expect(await typed(fixture.supervisor, fixture.session.id.agentTerminal).isEmpty)
  }

  @Test("A file dropped on a tab behind is typed into that tab, which comes in front")
  func tabBehind() async throws {
    let fixture = try await running(tabs: 2)
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let first = fixture.drawer.terminals[0]
    let second = fixture.drawer.terminals[1]
    #expect(fixture.drawer.activeTerminalID == second.id)
    let url = try file(named: "simple.txt", in: fixture)

    #expect(
      try await drop([url as NSURL], at: Self.firstTabPoint, on: fixture) {
        await !typed(fixture.supervisor, first.id).isEmpty
      })

    let kept = "/Drops/\(fixture.session.id.rawValue.uuidString)/simple.txt "
    #expect(await typed(fixture.supervisor, first.id) == [kept])
    #expect(fixture.drawer.activeTerminalID == first.id)
    #expect(await typed(fixture.supervisor, second.id).isEmpty)
    #expect(await typed(fixture.supervisor, fixture.session.id.agentTerminal).isEmpty)
  }

  @Test("A tab dragged onto another still moves before it, and types nothing")
  func reorder() async throws {
    let fixture = try await running(tabs: 2)
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let first = fixture.drawer.terminals[0]
    let second = fixture.drawer.terminals[1]

    #expect(
      try await drop(
        [DrawerTabDrag.text(for: second.id) as NSString], at: Self.firstTabPoint, on: fixture
      ) { fixture.drawer.terminals.first?.id == second.id })

    #expect(fixture.drawer.terminals.map(\.id) == [second.id, first.id])
    #expect(await typed(fixture.supervisor, first.id).isEmpty)
    #expect(await typed(fixture.supervisor, second.id).isEmpty)
  }

  @Test("A side terminal whose shell ended refuses the drop, and types nothing")
  func ended() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let side = try #require(fixture.drawer.activeTerminal)
    let shell = try #require(await fixture.supervisor.session(for: side.id) as? WorkspaceTerminal)
    await shell.finish(state: .exited(code: 1))
    await waitUntil { side.pane.status != .running }
    #expect(
      fixture.model.dropRoute(for: fixture.session.id, target: .sideTerminal(side.id))
        == .refused(.shellNotRunning))
    let url = try file(named: "simple.txt", in: fixture)

    #expect(try await !drop([url as NSURL], at: Self.terminalPoint, on: fixture))

    #expect(await typed(fixture.supervisor, side.id).isEmpty)
    #expect(await typed(fixture.supervisor, fixture.session.id.agentTerminal).isEmpty)
    #expect(
      AppModel.refusalAnnouncement(.shellNotRunning, name: "zsh")
        == "Nothing dropped: the shell of zsh is not running.")
  }
}
