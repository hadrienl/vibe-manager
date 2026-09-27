import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import VibeApplication
import VibeConversationUI
import VibeDomain

@testable import VibeUI

/// What drops wrote, and what was removed.
private actor RecordingDropStore: SessionDropStore {
  private(set) var saved: [(name: String, id: SessionID)] = []
  private(set) var removed: [SessionID] = []
  private(set) var sweeps: [Set<SessionID>] = []

  func save(_ data: Data, suggestedName: String, for id: SessionID) -> URL {
    saved.append((suggestedName, id))
    return URL(fileURLWithPath: "/Drops/\(id.rawValue.uuidString)/\(suggestedName)")
  }

  func copy(_ file: URL, suggestedName: String, for id: SessionID) -> URL {
    saved.append((suggestedName, id))
    return URL(fileURLWithPath: "/Drops/\(id.rawValue.uuidString)/\(suggestedName)")
  }

  func remove(_ id: SessionID) { removed.append(id) }

  func sweep(keeping ids: Set<SessionID>) { sweeps.append(ids) }
}

/// A clock whose sleeps end when the test says so.
private actor ManualSleeper {
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var sleeping: Int { waiters.count }

  func sleep() async {
    await withCheckedContinuation { waiters.append($0) }
  }

  func wake() {
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

@Suite("Where a drop on a session goes (#42)")
struct SessionDropRouteTests {
  @Test("A terminal takes a drop while its process runs, and refuses it otherwise")
  func terminal() {
    #expect(
      SessionDropRoute.decide(
        isArchived: false, presentation: .terminal, isProcessRunning: true, composer: nil)
        == .terminal(fallback: false))
    #expect(
      SessionDropRoute.decide(
        isArchived: false, presentation: .terminal, isProcessRunning: false, composer: .ready)
        == .refused(.stopped))
  }

  @Test(
    "A conversation takes a drop whenever joining a file is harmless",
    arguments: [
      (ConversationModel.ComposerState.ready, SessionDropRoute.conversation),
      (.awaitingAnswer, .conversation),
      (.starting, .conversation),
      (.stopped, .refused(.stopped)),
      (.unavailable, .terminal(fallback: true)),
    ])
  func conversation(state: ConversationModel.ComposerState, route: SessionDropRoute) {
    #expect(
      SessionDropRoute.decide(
        isArchived: false, presentation: .conversation, isProcessRunning: true, composer: state)
        == route)
  }

  @Test("A conversation not read yet follows its process; an archive takes nothing")
  func edges() {
    #expect(
      SessionDropRoute.decide(
        isArchived: false, presentation: .conversation, isProcessRunning: true, composer: nil)
        == .conversation)
    #expect(
      SessionDropRoute.decide(
        isArchived: false, presentation: .conversation, isProcessRunning: false, composer: nil)
        == .refused(.stopped))
    #expect(
      SessionDropRoute.decide(
        isArchived: false, presentation: .conversation, isProcessRunning: false,
        composer: .unavailable) == .refused(.stopped))
    #expect(
      SessionDropRoute.decide(
        isArchived: true, presentation: .terminal, isProcessRunning: true, composer: nil)
        == .refused(.archived))
  }
}

@MainActor
@Suite("A drag resting on a row selects its session (#42)")
struct SpringLoadingTests {
  private func waitUntil(_ condition: () async -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("It fires once the delay has passed over the same row")
  func fires() async {
    let sleeper = ManualSleeper()
    let loading = SpringLoading(sleep: { _ in await sleeper.sleep() })
    var fired: [SessionID] = []
    let id = SessionID()
    loading.enter(id) { fired.append(id) }
    loading.enter(id) { fired.append(id) }
    await waitUntil { await sleeper.sleeping == 1 }
    await sleeper.wake()
    await waitUntil { !fired.isEmpty }
    #expect(fired == [id])
  }

  @Test("Leaving the row, or moving to another, starts again")
  func leaves() async {
    let sleeper = ManualSleeper()
    let loading = SpringLoading(sleep: { _ in await sleeper.sleep() })
    var fired: [SessionID] = []
    let first = SessionID()
    let second = SessionID()
    loading.enter(first) { fired.append(first) }
    loading.exit(first)
    loading.enter(first) { fired.append(first) }
    loading.enter(second) { fired.append(second) }
    await waitUntil { await sleeper.sleeping == 3 }
    await sleeper.wake()
    await waitUntil { !fired.isEmpty }
    for _ in 0..<20 { await Task.yield() }
    #expect(fired == [second])
  }
}

@MainActor
@Suite("Reading what was dropped (#42)")
struct DropReaderTests {
  private func fileProvider(_ path: String, after delay: Double) -> NSItemProvider {
    let provider = NSItemProvider()
    let url = URL(fileURLWithPath: path)
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
    ) { completion in
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
        completion(url.dataRepresentation, nil)
      }
      return nil
    }
    return provider
  }

  private func png() throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  @Test("Files come back in the order of the drop, whatever order they load in")
  func order() async {
    let providers = [
      fileProvider("/Users/me/b", after: 0.15),
      fileProvider("/Users/me/a", after: 0.0),
      fileProvider("/Users/me/c", after: 0.05),
    ]
    let (items, failed) = await DropReader.read(providers)
    #expect(failed == 0)
    #expect(
      items == [
        .file(URL(fileURLWithPath: "/Users/me/b"), isTemporary: false),
        .file(URL(fileURLWithPath: "/Users/me/a"), isTemporary: false),
        .file(URL(fileURLWithPath: "/Users/me/c"), isTemporary: false),
      ])
  }

  @Test("An image dragged with its address keeps its bytes, not the address")
  func imageBeforeAddress() async throws {
    let data = try png()
    let provider = NSItemProvider(object: URL(string: "https://example.com/cat.png")! as NSURL)
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.png.identifier, visibility: .all
    ) { completion in
      completion(data, nil)
      return nil
    }
    provider.suggestedName = "cat"
    let (items, _) = await DropReader.read([provider])
    #expect(items == [.data(data, suggestedName: "cat.png")])
  }

  @Test("A web address and a text are text")
  func text() async {
    let (items, _) = await DropReader.read([
      NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL),
      NSItemProvider(object: "hello" as NSString),
    ])
    #expect(items == [.text("https://example.com/a"), .text("hello")])
  }

  @Test("A TIFF becomes a PNG named after the time when it has no name")
  func tiff() throws {
    let tiff = try #require(NSBitmapImageRep(data: try png())?.tiffRepresentation)
    guard
      case .data(let data, let name) = DropReader.imageItem(
        tiff, type: .tiff, suggestedName: nil)
    else {
      Issue.record("not an image")
      return
    }
    #expect(name.hasSuffix(".png"))
    #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  }

  @Test("A tab of the web view dragged along its strip is not text to type")
  func browserTab() async {
    let tab = BrowserTabDrag.text(for: BrowserTabID())
    let (items, failed) = await DropReader.read([NSItemProvider(object: tab as NSString)])
    #expect(items.isEmpty)
    #expect(failed == 0)
    #expect(BrowserTabDrag.tabID(in: "hello") == nil)
  }

  @Test("An image the agents read is kept as it is")
  func readableImage() throws {
    let data = try png()
    #expect(
      DropReader.imageItem(data, type: .png, suggestedName: "cat.png")
        == .data(data, suggestedName: "cat.png"))
  }

  @Test("A file in a temporary folder is one to keep")
  func temporary() {
    #expect(
      DropReader.isTemporary(
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Screenshot.png")))
    #expect(!DropReader.isTemporary(URL(fileURLWithPath: "/Users/me/Desktop/a.png")))
    let resolved = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    #expect(DropReader.isTemporary(URL(fileURLWithPath: "/private" + resolved + "/shot.png")))
  }
}

@MainActor
@Suite("Delivering a drop to a session (#42)")
struct SessionDropDeliveryTests {
  private static let provider = WorkspaceProvider()

  private func session(path: String) -> WorkSession {
    WorkSession(
      name: "Drops",
      initialPrompt: "Look at these.",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)]
    )
  }

  private func running() async throws -> (
    AppModel, WorkspaceSupervisor, RecordingDropStore, WorkSession
  ) {
    let path = NSTemporaryDirectory().appending("vibe-drop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let subject = session(path: path)
    let repository = WorkspaceRepository(sessions: [subject])
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let store = RecordingDropStore()
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, dropStore: store)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()
    model.select(subject.id)
    await waitUntil { model.pane(for: subject.id)?.status == .running }
    return (model, supervisor, store, subject)
  }

  private func typed(_ supervisor: WorkspaceSupervisor, _ id: SessionID) async -> [String] {
    guard let terminal = await supervisor.session(for: id) as? WorkspaceTerminal else {
      return []
    }
    return await terminal.written.map { String(decoding: $0, as: UTF8.self) }
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("Chosen files are typed into the terminal, escaped, without Return")
  func terminal() async throws {
    let (model, supervisor, _, subject) = try await running()
    #expect(model.canAttachFiles)
    await model.attachChosenFiles([
      URL(fileURLWithPath: "/Users/me/My File.png"), URL(fileURLWithPath: "/Users/me/b"),
    ])
    #expect(await typed(supervisor, subject.id) == [#"/Users/me/My\ File.png /Users/me/b "#])
  }

  @Test("An image without a file is kept in the session's folder, then its path typed")
  func imageIsKept() async throws {
    let (model, supervisor, store, subject) = try await running()
    await model.deliver(
      [.data(Data([1]), suggestedName: "cat.png"), .text("see")], unreadable: 0, to: subject.id)
    #expect(await store.saved.map(\.name) == ["cat.png"])
    let folder = subject.id.rawValue.uuidString
    #expect(await typed(supervisor, subject.id) == ["/Drops/\(folder)/cat.png see "])
  }

  @Test("What could not be read or written is said, and the rest is typed")
  func leftOut() async throws {
    let (model, supervisor, _, subject) = try await running()
    await model.deliver(
      [.file(URL(fileURLWithPath: "/a\u{1B}b"), isTemporary: false), .text("ok")],
      unreadable: 1, to: subject.id)
    #expect(await typed(supervisor, subject.id) == ["ok "])
    let notice = try #require(model.dropNotice)
    #expect(notice.sessionID == subject.id)
    #expect(notice.messages.count == 2)
    #expect(!notice.offersFullDiskAccess)
  }

  @Test("A stopped session refuses, types nothing and says why")
  func stopped() async throws {
    let (model, supervisor, _, subject) = try await running()
    await supervisor.finish(id: subject.id, state: .exited(code: 0))
    await waitUntil { model.pane(for: subject.id)?.status != .running }
    #expect(model.dropRoute(for: subject.id) == .refused(.stopped))
    #expect(!model.canAttachFiles)
    await model.attachChosenFiles([URL(fileURLWithPath: "/Users/me/a")])
    #expect(await typed(supervisor, subject.id).isEmpty)
    // What VoiceOver hears; `Announcer.lastAnnouncement` is shared with tests running beside.
    #expect(
      AppModel.refusalAnnouncement(.stopped, name: "Drops") == "Nothing dropped: Drops is stopped.")
  }

  @Test("Archiving a session removes what its drops wrote")
  func archive() async throws {
    let (model, _, store, subject) = try await running()
    await model.archive(subject.id)
    #expect(await store.removed == [subject.id])
  }

  @Test("A launch sweeps the folders of sessions archived or gone")
  func sweep() async throws {
    let active = session(path: "/tmp")
    var archived = session(path: "/tmp")
    try archived.archive(at: Date(timeIntervalSince1970: 2))
    let store = RecordingDropStore()
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [active, archived]),
      agents: WorkspaceRegistry(providers: [Self.provider]), dropStore: store)
    await model.load()
    await waitUntil { await !store.sweeps.isEmpty }
    #expect(await store.sweeps == [[active.id]])
  }
}
