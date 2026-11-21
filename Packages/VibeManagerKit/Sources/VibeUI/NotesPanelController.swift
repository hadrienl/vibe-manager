import AppKit
import Observation
import SwiftUI

/// The notes' floating window (#578): a utility panel above the application's windows, moved and
/// resized as any window. It hides while another application is in front, like every panel.
final class NotesPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
      styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
    level = .floating
    hidesOnDeactivate = true
    // Typed into: it takes the keyboard on a click, not only when a field asks for it.
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    minSize = NSSize(width: 260, height: 220)
    collectionBehavior = [.fullScreenAuxiliary]
    isExcludedFromWindowsMenu = true
    setAccessibilityIdentifier("notes-panel")
  }

  // The workspace window stays the main one: its menus and ⇧⌘W still talk to the session.
  override var canBecomeMain: Bool { false }
}

/// Shows and hides the notes' panel as `NotesPresentation` says, titles it after the session on
/// screen, and tells the presentation when the panel holds the keyboard.
///
/// The place and the size are AppKit's to keep, under the panel's frame name: the user finds the
/// panel where they left it, from one launch to the next.
@MainActor
public final class NotesPanelController: NSObject, NSWindowDelegate {
  static let frameName = "VibeNotesPanel"

  private let model: AppModel
  private(set) var panel: NotesPanel?

  public init(model: AppModel) {
    self.model = model
    super.init()
    model.notesPresentation.returnFromPanel = { [weak self] in self?.returnKeyboard() }
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = model.notesPresentation.isPanelShown
      _ = title
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.update()
        self?.observe()
      }
    }
    update()
  }

  private func update() {
    if model.notesPresentation.isPanelShown {
      show()
    } else {
      hide()
    }
    panel?.title = title
  }

  /// “Notes · the session's name”, or the notes alone without a session.
  var title: String {
    guard model.canShowNotes, let session = model.selectedSession else {
      return String(
        localized: "Notes", bundle: .module, comment: "The heading of a session's notes.")
    }
    return String(
      localized: "Notes · \(session.name)", bundle: .module,
      comment: "The title of the notes' floating window: the session's name.")
  }

  /// The panel and everything in it, never shown here: tests read it without a window on screen.
  func makePanel() -> NotesPanel {
    let panel = NotesPanel()
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: NotesPanelContent(model: model))
    let accessory = NSTitlebarAccessoryViewController()
    let button = NSHostingView(rootView: NotesReattachButton(model: model))
    button.frame.size = button.fittingSize
    accessory.view = button
    accessory.layoutAttribute = .trailing
    panel.addTitlebarAccessoryViewController(accessory)
    panel.title = title
    if !panel.setFrameUsingName(Self.frameName) {
      place(panel)
    }
    panel.setFrameAutosaveName(Self.frameName)
    return panel
  }

  /// The first time: at the top right of the workspace window, over the conversation.
  private func place(_ panel: NotesPanel) {
    guard let main = NSApp.mainWindow else {
      panel.center()
      return
    }
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(x: main.frame.maxX - size.width - 24, y: main.frame.maxY - size.height - 72))
  }

  private func show() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    guard !panel.isVisible else { return }
    panel.makeKeyAndOrderFront(nil)
  }

  private func hide() {
    guard let panel, panel.isVisible else { return }
    if panel.isKeyWindow { returnKeyboard() }
    panel.orderOut(nil)
  }

  /// The workspace window takes the keyboard back: Escape in the panel's editor, a second Edit
  /// Notes, the panel put away.
  private func returnKeyboard() {
    let workspace = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    workspace?.makeKeyAndOrderFront(nil)
  }

  // MARK: NSWindowDelegate

  /// Its own button, or ⌘W.
  public func windowWillClose(_ notification: Notification) {
    model.notesPanelClosed()
  }

  public func windowDidBecomeKey(_ notification: Notification) {
    model.notesPresentation.isPanelKey = true
  }

  public func windowDidResignKey(_ notification: Notification) {
    model.notesPresentation.isPanelKey = false
  }
}
