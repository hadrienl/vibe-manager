import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The notes from the toolbar (#578): the popover under the button, the floating panel, Edit Notes.
@MainActor
@Suite("Notes in the toolbar", .serialized, .timeLimit(.minutes(2)))
struct NotesPresentationTests {
  private struct Workspace {
    let model: AppModel
    let store: InMemorySessionNotesStore
    let first: WorkSession
    let second: WorkSession
  }

  private func workspace(
    notes: [Int: String] = [:], layout: WorkspaceLayout = WorkspaceLayout()
  ) async -> Workspace {
    let first = WorkSession(name: "First", status: .closed)
    let second = WorkSession(name: "Second", status: .closed)
    let ids = [first.id, second.id]
    let store = InMemorySessionNotesStore(
      notes: Dictionary(uniqueKeysWithValues: notes.map { (ids[$0.key], $0.value) }))
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [first, second]),
      layout: WorkspaceLayoutController(layout: layout), notesStore: store)
    await model.load()
    model.select(first.id)
    return Workspace(model: model, store: store, first: first, second: second)
  }

  /// Types at the end of a session's notes, as the editor would.
  private func type(_ text: String, in document: NotesDocument) {
    document.storage.append(NSAttributedString(string: text, attributes: NotesStyle.attributes))
    document.didChange()
  }

  @Test("Edit Notes opens the popover and hands its editor the keyboard; again, gives it back")
  func editNotesOpensThePopover() async {
    let workspace = await workspace()
    let model = workspace.model

    model.focusNotes()

    // Held by the model, not by the button: a button in the toolbar's overflow menu opens it as
    // soon as it is back in the toolbar.
    #expect(model.notesPresentation.isPopoverShown)
    #expect(!model.notesPresentation.isPanelShown)
    #expect(model.notes.wantsFocus)
    model.notes.focusTaken()

    model.focusNotes()
    #expect(!model.notesPresentation.isPopoverShown)
  }

  @Test("Closing the popover writes what waited for a pause")
  func closingWrites() async throws {
    let workspace = await workspace()
    let model = workspace.model
    let document = model.notes.document(for: workspace.first.id)
    await waitUntil("the notes are read") { document.isLoaded }
    model.toggleNotes()

    type("Check the seam", in: document)
    #expect(document.hasUnsavedChanges)
    model.notesPopoverDismissed()

    await waitUntil("the notes are written") { !document.hasUnsavedChanges }
    #expect(try await workspace.store.notes(for: workspace.first.id).text == "Check the seam")
    #expect(!model.notesPresentation.isPopoverShown)
  }

  @Test("Another session closes the popover")
  func anotherSessionClosesThePopover() async {
    let workspace = await workspace()
    let model = workspace.model
    model.toggleNotes()
    #expect(model.notesPresentation.isPopoverShown)

    model.select(workspace.second.id)

    #expect(!model.notesPresentation.isPopoverShown)
  }

  @Test("The button's sheet has lines once the notes hold more than blanks")
  func iconFollowsTheNotes() async {
    let workspace = await workspace(notes: [1: "Already written"])
    let model = workspace.model
    await waitUntil("the notes are indexed") { model.notes.hasNotes(for: workspace.second.id) }
    #expect(!model.selectedSessionHasNotes)

    let document = model.notes.document(for: workspace.first.id)
    await waitUntil("the notes are read") { document.isLoaded }
    type("  \n", in: document)
    #expect(!model.selectedSessionHasNotes)
    type("A decision", in: document)
    #expect(model.selectedSessionHasNotes)

    model.select(workspace.second.id)
    #expect(model.selectedSessionHasNotes)
  }

  @Test("Detach opens the panel, Reattach the popover again, and the layout keeps the choice")
  func detachAndReattach() async {
    let workspace = await workspace()
    let model = workspace.model
    model.toggleNotes()

    model.detachNotes()
    #expect(model.notesPresentation.isPanelShown)
    #expect(!model.notesPresentation.isPopoverShown)
    #expect(model.layout.intent.notesPlacement == .panel)

    // The button shows and hides the panel from now on.
    model.toggleNotes()
    #expect(!model.notesPresentation.isPanelShown)
    #expect(!model.notesPresentation.isPopoverShown)
    model.toggleNotes()
    #expect(model.notesPresentation.isPanelShown)

    model.attachNotes()
    #expect(model.notesPresentation.isPopoverShown)
    #expect(!model.notesPresentation.isPanelShown)
    #expect(model.layout.intent.notesPlacement == .popover)
  }

  @Test("At launch the panel is closed, and Edit Notes opens it, where the user keeps the notes")
  func placementKept() async {
    let workspace = await workspace(layout: WorkspaceLayout(notesPlacement: .panel))
    let model = workspace.model
    #expect(!model.notesPresentation.isShown)

    model.focusNotes()

    #expect(model.notesPresentation.isPanelShown)
    #expect(!model.notesPresentation.isPopoverShown)
    #expect(model.notes.wantsFocus)
  }

  @Test("The panel follows the session on screen, and the one left has its notes written")
  func panelFollowsTheSelection() async throws {
    let workspace = await workspace()
    let model = workspace.model
    model.detachNotes()
    let document = model.notes.document(for: workspace.first.id)
    await waitUntil("the notes are read") { document.isLoaded }
    type("Left mid-sentence", in: document)

    model.select(workspace.second.id)

    #expect(model.notesPresentation.isPanelShown)
    await waitUntil("the notes are written") { !document.hasUnsavedChanges }
    #expect(try await workspace.store.notes(for: workspace.first.id).text == "Left mid-sentence")
  }

  @Test("The panel closed by its own button stays closed, its placement kept")
  func panelClosed() async {
    let workspace = await workspace()
    let model = workspace.model
    model.detachNotes()

    model.notesPanelClosed()

    #expect(!model.notesPresentation.isShown)
    #expect(model.notesPresentation.placement == .panel)
  }

  @Test("Without a session, or behind a new session's draft, the button opens nothing")
  func noSession() async {
    let model = AppModel(repository: WorkspaceRepository(sessions: []))
    await model.load()
    #expect(!model.canShowNotes)

    model.toggleNotes()
    model.focusNotes()

    #expect(!model.notesPresentation.isShown)
  }
}

/// What the popover and the panel hold, in windows never put on screen.
@MainActor
@Suite("The notes' popover and panel", .serialized, .timeLimit(.minutes(2)))
struct NotesPresentationViewTests {
  private static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { all(type, in: $0) }
  }

  private static func editor(in view: NSView?) -> NSTextView? {
    all(NSTextView.self, in: view).first { $0.accessibilityIdentifier() == "notes-editor" }
  }

  private func model() async -> (AppModel, WorkSession) {
    let session = WorkSession(name: "Views", status: .closed)
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [session]),
      notesStore: InMemorySessionNotesStore())
    await model.load()
    model.select(session.id)
    return (model, session)
  }

  @Test("Reattaching really closes the panel and preserves typing before either view disappears")
  func typingDetachReattach() async throws {
    _ = NSApplication.shared
    let (model, session) = await model()
    let controller = NotesPanelController(model: model)
    let document = model.notes.document(for: session.id)
    await waitUntil("the notes are loaded") { document.isLoaded }
    let host = NSHostingView(rootView: NotesPopoverContent(model: model, session: session))
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 460),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      model.notesPanelClosed()
      window.contentView = nil
      window.close()
    }
    model.toggleNotes()
    await waitUntil("the popover editor") { Self.editor(in: host) != nil }
    let popover = try #require(Self.editor(in: host))
    popover.insertText(
      "Typed immediately before detaching", replacementRange: NSRange(location: 0, length: 0))

    model.detachNotes()
    let panel = try #require(controller.panel)
    panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    #expect(panel.isVisible)
    #expect(!model.notesPresentation.isPopoverShown)
    await waitUntil("the panel editor") { Self.editor(in: panel.contentView) != nil }
    let panelEditor = try #require(Self.editor(in: panel.contentView))
    #expect(panelEditor.string == "Typed immediately before detaching")
    panelEditor.insertText(
      " and in the panel",
      replacementRange: NSRange(location: panelEditor.string.utf16.count, length: 0))

    model.attachNotes()
    #expect(!panel.isVisible)
    #expect(panel.contentView == nil)
    #expect(controller.panel == nil)
    #expect(!model.notesPresentation.isPanelShown)
    #expect(model.notesPresentation.isPopoverShown)
    #expect(popover.string == "Typed immediately before detaching and in the panel")
    // Let pending SwiftUI focus requests run: none may bring the old window back.
    for _ in 0..<10 { await Task.yield() }
    #expect(!panel.isVisible)
    #expect(document.text == "Typed immediately before detaching and in the panel")
    #expect(await document.save())
  }

  @Test("The popover holds the session's editor and the Detach button")
  func popover() async throws {
    let (model, session) = await model()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 460), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
      window.contentView = nil
      window.close()
    }
    let host = NSHostingView(rootView: NotesPopoverContent(model: model, session: session))
    window.contentView = host

    await waitUntil("the editor") { Self.editor(in: host) != nil }
    #expect(Self.editor(in: host)?.accessibilityLabel() == "Notes for Views")
  }

  @Test("The panel holds the editor, and Reattach in its title bar; its title names the session")
  func panel() async throws {
    let (model, _) = await model()
    let controller = NotesPanelController(model: model)
    let panel = controller.makePanel()
    defer {
      panel.contentView = nil
      panel.close()
    }

    #expect(!panel.isVisible)
    #expect(panel.title == "Notes · Views")
    #expect(panel.styleMask.contains(.resizable))
    #expect(panel.level == .floating)
    #expect(panel.titlebarAccessoryViewControllers.count == 1)
    #expect(
      panel.titlebarAccessoryViewControllers.first?.view is NSHostingView<NotesReattachButton>)
    await waitUntil("the editor") { Self.editor(in: panel.contentView) != nil }
  }
}
