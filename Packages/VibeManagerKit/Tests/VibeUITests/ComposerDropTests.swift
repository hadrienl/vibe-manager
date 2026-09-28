import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

@testable import VibeConversationUI
@testable import VibeUI

/// A Finder drag let go on the composer's text field, in a real window: the conversation's own
/// view in the session's drop zone, a real pasteboard, and the view AppKit hands the drag to — the
/// frontmost visible one under the pointer registered for one of its types (#146).
@MainActor
@Suite("Dropping on the composer's text field (#146)")
struct ComposerDropTests {
  private static let provider = WorkspaceProvider()
  private static let size = NSSize(width: 700, height: 500)

  private struct Fixture {
    let model: AppModel
    let supervisor: WorkspaceSupervisor
    let conversation: ConversationModel
    let session: WorkSession
    let folder: URL
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// A running session shown in conversation, its composer ready.
  private func running() async throws -> Fixture {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerDropTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Drops",
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
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, dropStore: KeepingDropStore())
    model.connectConversations()
    model.conversations.readableAgents = [
      "stub": ConversationWorkspace.Agent(name: "Stub Agent", format: AgentPromptFormat())
    ]
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder.path))
    await launcher.launch(session: session, plan: plan)
    await model.reload()
    model.select(session.id)
    await waitUntil { model.pane(for: session.id)?.status == .running }
    model.setPresentation(.conversation, of: session.id)
    let conversation = model.conversations.show(session)
    // Read, and empty: the view shows its composer.
    conversation.follow(
      AsyncStream { continuation in
        continuation.yield(
          ConversationSnapshot(availability: .notYetWritten(providerName: "Stub Agent")))
      })
    await waitUntil { conversation.snapshot.availability != .loading }
    #expect(conversation.composerState == .ready)
    #expect(model.dropRoute(for: session.id) == .conversation)
    return Fixture(
      model: model, supervisor: supervisor, conversation: conversation, session: session,
      folder: folder)
  }

  /// What the field made of a drag: whether it was taken, and the operation proposed.
  private struct Outcome {
    let proposed: NSDragOperation
    let taken: Bool
  }

  /// Lets `objects` go in the middle of the composer's text field, handing the drag to the view
  /// AppKit would: the frontmost one under the pointer registered for drags — the text view.
  private func dropOnField(
    _ objects: [any NSPasteboardWriting], on fixture: Fixture,
    sourceMask: NSDragOperation = .copy, until delivered: () async -> Bool = { true }
  ) async throws -> Outcome {
    let host = NSHostingView(
      rootView: ConversationView(
        model: fixture.conversation, theme: .systemLight,
        appearance: fixture.model.conversations.appearance
      )
      .modifier(SessionDropZone(model: fixture.model, sessionID: fixture.session.id))
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
    let textView = try #require(Self.textView(in: host))
    // As in a window on screen: the text view registers the types it reads.
    textView.updateDragTypeRegistration()
    let location = textView.convert(
      NSPoint(x: textView.bounds.midX, y: textView.bounds.midY), to: nil)

    let pasteboard = NSPasteboard(name: .init("ComposerDropTests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(objects)
    let types = pasteboard.types ?? []
    let destination = try #require(Self.dropDestination(in: host, at: location, for: types))
    // AppKit's own choice, where it can be asked: the same view.
    if let chosen = Self.appKitDestination(in: window, at: location, for: types) {
      #expect(chosen === destination)
    }
    // A file for the catcher laid over the field, a text for the field itself.
    if ComposerDropPassage.carriesFiles(pasteboard) {
      #expect(destination is ComposerFileDropCatcher.CatcherView)
    } else {
      #expect(destination === textView)
    }
    let drag = PasteboardDrag(
      pasteboard: pasteboard, location: location, window: window, sourceMask: sourceMask)
    _ = destination.draggingEntered(drag)
    let proposed = destination.draggingUpdated(drag)
    _ = destination.prepareForDragOperation(drag)
    let taken = destination.performDragOperation(drag)
    destination.concludeDragOperation(drag)
    destination.draggingEnded(drag)
    if taken { await waitUntil(delivered) }
    return Outcome(proposed: proposed, taken: taken)
  }

  private static func textView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    return view.subviews.lazy.compactMap(textView(in:)).first
  }

  /// The frontmost visible view under `location`, in the window's coordinates, registered for
  /// one of `types` — as AppKit chooses a drag's destination, without asking `hitTest(_:)`.
  private static func dropDestination(
    in view: NSView, at location: NSPoint, for types: [NSPasteboard.PasteboardType]
  ) -> NSView? {
    guard !view.isHidden, view.bounds.contains(view.convert(location, from: nil)) else {
      return nil
    }
    for subview in view.subviews.reversed() {
      if let found = dropDestination(in: subview, at: location, for: types) { return found }
    }
    let registered = Set(view.registeredDraggedTypes)
    let general = registered.compactMap { UTType($0.rawValue) }
    let takes = types.contains { type in
      registered.contains(type)
        || UTType(type.rawValue).map { uti in general.contains { uti.conforms(to: $0) } } == true
    }
    return takes ? view : nil
  }

  /// AppKit's own lookup, `-[NSView _hitTest:dragTypes:]`, when it answers: a private method,
  /// asked here only, to check the test's reading of it.
  private static func appKitDestination(
    in window: NSWindow, at location: NSPoint, for types: [NSPasteboard.PasteboardType]
  ) -> NSView? {
    typealias Lookup =
      @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
    let selector = NSSelectorFromString("_hitTest:dragTypes:")
    guard let frame = window.contentView?.superview, frame.responds(to: selector),
      let implementation = class_getMethodImplementation(type(of: frame), selector)
    else { return nil }
    var point = frame.convert(location, from: nil)
    let lookup = unsafeBitCast(implementation, to: Lookup.self)
    return lookup(frame, selector, &point, NSSet(array: types.map(\.rawValue)))
  }

  private func file(named name: String, in fixture: Fixture) throws -> URL {
    let url = fixture.folder.appendingPathComponent(name)
    try Data("a\n".utf8).write(to: url)
    return url
  }

  private func kept(_ name: String, _ fixture: Fixture) -> URL {
    URL(fileURLWithPath: "/Drops/\(fixture.session.id.rawValue.uuidString)/\(name)")
  }

  @Test("Files let go on the field become chips, in order, and the field is left alone")
  func files() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let first = try file(named: "simple.txt", in: fixture)
    let second = try file(named: "deuxième fichier.md", in: fixture)

    let outcome = try await dropOnField([first as NSURL, second as NSURL], on: fixture) {
      fixture.conversation.attachments.count == 2
    }

    #expect(outcome.taken)
    #expect(outcome.proposed == .copy)
    // Files of the temporary folder are kept in the session's drop folder, as #42 does.
    #expect(
      fixture.conversation.attachments == [
        kept("simple.txt", fixture), kept("deuxième fichier.md", fixture),
      ])
    #expect(fixture.conversation.draft.isEmpty)
  }

  @Test("An image with no file let go on the field becomes a chip too")
  func image() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let item = NSPasteboardItem()
    item.setData(try #require(bitmap.representation(using: .png, properties: [:])), forType: .png)

    let outcome = try await dropOnField([item], on: fixture) {
      fixture.conversation.attachments.count == 1
    }

    #expect(outcome.taken)
    #expect(fixture.conversation.attachments.count == 1)
    #expect(fixture.conversation.draft.isEmpty)
  }

  @Test("A text let go on the field is inserted in it, and makes no chip")
  func text() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }

    let outcome = try await dropOnField(
      ["npm run dev" as NSString], on: fixture, sourceMask: [.copy, .generic]
    ) { fixture.conversation.draft.contains("npm run dev") }

    #expect(outcome.taken)
    #expect(fixture.conversation.draft == "npm run dev")
    #expect(fixture.conversation.attachments.isEmpty)
  }

  @Test("A file let go on the field of a stopped session is refused, and makes no chip")
  func stopped() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let agent = try #require(
      await fixture.supervisor.session(for: fixture.session.id.agentTerminal)
        as? WorkspaceTerminal)
    await agent.finish(state: .exited(code: 0))
    await waitUntil { fixture.conversation.composerState == .stopped }
    #expect(fixture.model.dropRoute(for: fixture.session.id) == .refused(.stopped))
    let url = try file(named: "simple.txt", in: fixture)

    let outcome = try await dropOnField([url as NSURL], on: fixture)

    #expect(!outcome.taken)
    #expect(!outcome.proposed.contains(.copy))
    #expect(fixture.conversation.attachments.isEmpty)
    #expect(fixture.conversation.draft.isEmpty)
  }

  @Test("Only a drag carrying a file, an image or a promised file passes through the field")
  func carriesFiles() throws {
    let pasteboard = NSPasteboard(name: .init("ComposerDropTests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    func carries(_ objects: [any NSPasteboardWriting]) -> Bool {
      pasteboard.clearContents()
      pasteboard.writeObjects(objects)
      return ComposerDropPassage.carriesFiles(pasteboard)
    }
    #expect(carries([URL(fileURLWithPath: "/tmp/simple.txt") as NSURL]))
    let image = NSPasteboardItem()
    image.setData(Data([0]), forType: .tiff)
    #expect(carries([image]))
    let promise = NSPasteboardItem()
    for type in NSFilePromiseReceiver.readableDraggedTypes {
      promise.setData(Data(), forType: .init(type))
    }
    #expect(carries([promise]))
    #expect(!carries(["hello" as NSString]))
    #expect(!carries([try #require(NSURL(string: "https://example.com/a"))]))
    let html = NSPasteboardItem()
    html.setString("<b>hello</b>", forType: .html)
    html.setString("hello", forType: .string)
    #expect(!carries([html]))
  }
}
