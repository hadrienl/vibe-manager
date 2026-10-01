import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A Finder drag let go on the new session's draft, in the real window — never put on screen: the
/// draft drawn over a running session, a real pasteboard, and the view AppKit hands the drag to.
///
/// Before, AppKit found no destination on the draft but the prompt's text view, which typed the
/// path where it was let go; the draft's SwiftUI drop destination lay behind everything, and the
/// session's own zone, under the draft, would have typed the file into a terminal out of sight.
@MainActor
@Suite("Dropping files on the new session's draft", .serialized, .timeLimit(.minutes(2)))
struct NewSessionDropTests {
  private static let size = NSSize(width: 1200, height: 800)

  @MainActor private final class Workspace {
    let model: AppModel
    let session: WorkSession
    let window: NSWindow
    let folder: URL

    init(model: AppModel, session: WorkSession, window: NSWindow, folder: URL) {
      self.model = model
      self.session = session
      self.window = window
      self.folder = folder
    }

    var draft: NewSessionModel? { model.newSessionModel }

    var catcher: NewSessionDropCatcher.CatcherView? {
      Self.all(NewSessionDropCatcher.CatcherView.self, in: window.contentView).first
    }

    /// The working folder's field.
    var folderField: NSTextField? {
      Self.all(NSTextField.self, in: window.contentView).first {
        $0.placeholderString == String(localized: "Choose a folder", bundle: .module)
      }
    }

    /// The prompt's field: the draft's only text view, drawn in front of the session's.
    var promptField: NSTextView? {
      Self.all(NSTextView.self, in: window.contentView).first {
        $0.accessibilityLabel() == String(localized: "Initial prompt", bundle: .module)
      }
    }

    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(at: folder)
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
      guard let view else { return [] }
      let own = (view as? T).map { [$0] } ?? []
      return own + view.subviews.flatMap { all(type, in: $0) }
    }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// A running session selected, its terminal on screen, and a new session's draft over it.
  private func workspace() async throws -> Workspace {
    let launch = try await StubSessionLaunch.make(named: "Behind", dropStore: KeepingDropStore())
    let (model, session, folder) = (launch.model, launch.session, launch.folder)
    await waitUntil { model.pane(for: session.id)?.status == .running }

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    let workspace = Workspace(model: model, session: session, window: window, folder: folder)
    model.beginNewSession()
    await waitUntil { workspace.catcher != nil && workspace.promptField != nil }
    window.contentView?.layoutSubtreeIfNeeded()
    // As in a window on screen: the text view registers the types it reads.
    workspace.promptField?.updateDragTypeRegistration()
    return workspace
  }

  /// What a drag made of the draft: the view it went to, whether it was taken, and the operation
  /// proposed.
  private struct Outcome {
    let destination: NSView
    let proposed: NSDragOperation
    let taken: Bool
  }

  /// Lets `objects` go at `location`, in the window's coordinates, handing the drag to the view
  /// AppKit would: the frontmost one under the pointer registered for one of its types.
  private func drop(
    _ objects: [any NSPasteboardWriting], at location: NSPoint, on workspace: Workspace,
    sourceMask: NSDragOperation = .copy
  ) throws -> Outcome {
    let pasteboard = NSPasteboard(name: .init("NewSessionDropTests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(objects)
    let types = pasteboard.types ?? []
    let root = try #require(workspace.window.contentView?.superview)
    let destination = try #require(Self.dropDestination(in: root, at: location, for: types))
    // AppKit's own choice, where it can be asked: the same view.
    if let chosen = Self.appKitDestination(in: workspace.window, at: location, for: types) {
      #expect(chosen === destination)
    }
    let drag = PasteboardDrag(
      pasteboard: pasteboard, location: location, window: workspace.window,
      sourceMask: sourceMask)
    _ = destination.draggingEntered(drag)
    let proposed = destination.draggingUpdated(drag)
    _ = destination.prepareForDragOperation(drag)
    let taken = destination.performDragOperation(drag)
    destination.concludeDragOperation(drag)
    destination.draggingEnded(drag)
    return Outcome(destination: destination, proposed: proposed, taken: taken)
  }

  /// Points of the draft, in the window's coordinates: its header, its options card, its prompt's
  /// field, and the bar under the field.
  private func points(of workspace: Workspace) throws -> [String: NSPoint] {
    let catcher = try #require(workspace.catcher)
    let field = try #require(workspace.promptField)
    let draft = catcher.convert(catcher.bounds, to: nil)
    let prompt = field.convert(field.bounds, to: nil)
    return [
      "header": NSPoint(x: draft.midX, y: draft.maxY - 15),
      "card": NSPoint(x: draft.midX, y: draft.midY + 60),
      "field": NSPoint(x: prompt.midX, y: prompt.midY),
      "bar": NSPoint(x: draft.midX, y: prompt.minY - 12),
    ]
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

  private func file(named name: String, in workspace: Workspace) throws -> URL {
    let url = workspace.folder.appendingPathComponent(name)
    try Data("a\n".utf8).write(to: url)
    return url
  }

  @Test("A file let go anywhere on the draft becomes a chip, and never reaches the session behind")
  func anywhere() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let draft = try #require(workspace.draft)
    let url = try file(named: "deuxième fichier.md", in: workspace)

    for (place, location) in try points(of: workspace) {
      draft.draft.initialPrompt = "Read"
      draft.draft.attachments = []
      let outcome = try drop([url as NSURL], at: location, on: workspace)

      #expect(outcome.destination === workspace.catcher, "\(place)")
      #expect(outcome.taken, "\(place)")
      #expect(outcome.proposed == .copy, "\(place)")
      #expect(draft.draft.attachments == [url], "\(place)")
      #expect(draft.draft.initialPrompt == "Read", "\(place)")
    }
    #expect(workspace.model.dropNotice == nil)
  }

  @Test("Files let go together become chips in their order")
  func several() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let draft = try #require(workspace.draft)
    let first = try file(named: "a.txt", in: workspace)
    let second = try file(named: "b.txt", in: workspace)

    let card = try #require(try points(of: workspace)["card"])
    let outcome = try drop([first as NSURL, second as NSURL], at: card, on: workspace)

    #expect(outcome.taken)
    #expect(draft.draft.attachments == [first, second])
    #expect(draft.draft.initialPrompt.isEmpty)
  }

  @Test("A file is refused over a template's prompt, which stays as it is")
  func template() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let draft = try #require(workspace.draft)
    draft.draft.templateFill = PromptTemplateFill(
      template: PromptTemplate(name: "Review", body: "Review the branch"))
    let url = try file(named: "a.txt", in: workspace)

    let card = try #require(try points(of: workspace)["card"])
    let outcome = try drop([url as NSURL], at: card, on: workspace)

    #expect(outcome.destination === workspace.catcher)
    #expect(!outcome.taken)
    #expect(!outcome.proposed.contains(.copy))
    #expect(draft.draft.initialPrompt.isEmpty)
    #expect(draft.draft.attachments.isEmpty)
    #expect(workspace.model.dropNotice == nil)
  }

  @Test("A text let go on the prompt's field goes to the field")
  func text() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }

    let field = try #require(try points(of: workspace)["field"])
    let outcome = try drop(
      ["npm run dev" as NSString], at: field, on: workspace, sourceMask: [.copy, .generic])

    #expect(outcome.destination === workspace.promptField)
  }

  @Test("A folder let go on the working folder becomes the session's, and joins nothing")
  func folderOnTheWorkingFolder() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let draft = try #require(workspace.draft)
    let field = try #require(workspace.folderField)
    let folder = workspace.folder.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let location = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)

    let outcome = try drop([folder as NSURL], at: location, on: workspace)
    await waitUntil { draft.draft.workingDirectoryPath == folder.path }

    #expect(outcome.taken)
    #expect(draft.draft.workingDirectoryPath == folder.path)
    #expect(draft.draft.attachments.isEmpty)

    // Elsewhere, the same folder is a file joined to the prompt.
    let card = try #require(try points(of: workspace)["card"])
    _ = try drop([folder as NSURL], at: card, on: workspace)
    #expect(draft.draft.attachments == [folder])
  }
}
