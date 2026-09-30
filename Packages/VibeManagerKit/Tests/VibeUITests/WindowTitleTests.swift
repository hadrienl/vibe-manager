import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// "Vibe Manager › <session>" in the window's header (#159).
@MainActor
@Suite("The window's title names the session on screen")
struct WindowTitleTests {
  @Test("Before the sessions are read, and with none selected, the title is the application alone")
  func applicationAlone() async {
    let model = AppModel(repository: StubRepository(sessions: []))
    #expect(model.windowTitle.full == "Vibe Manager")

    await model.load()

    #expect(model.windowTitle.sessionName == nil)
    #expect(model.windowTitle.full == "Vibe Manager")
    #expect(model.windowTitle.spoken == "Vibe Manager")
  }

  @Test("The session selected follows the application, and the title follows the selection")
  func followsTheSelection() async {
    let first = WorkSession(name: "Alpha", updatedAt: Date(timeIntervalSince1970: 200))
    let second = WorkSession(name: "Beta", updatedAt: Date(timeIntervalSince1970: 100))
    let model = AppModel(repository: StubRepository(sessions: [first, second]))
    await model.load()

    model.select(first.id)
    #expect(model.windowTitle.full == "Vibe Manager › Alpha")

    model.select(second.id)
    #expect(model.windowTitle.full == "Vibe Manager › Beta")

    model.select(nil)
    #expect(model.windowTitle.full == "Vibe Manager")
  }

  @Test("An archived session shown is named like any other")
  func archivedSession() async {
    let archived = WorkSession(name: "Old work", status: .archived)
    let model = AppModel(repository: StubRepository(sessions: [archived]))
    await model.load()

    model.select(archived.id)

    #expect(model.windowTitle.full == "Vibe Manager › Old work")
  }

  @Test("A session renamed is renamed in the title")
  func followsARename() async {
    let session = WorkSession(name: "Before")
    let repository = StubRepository(sessions: [session])
    let model = AppModel(repository: repository)
    await model.load()
    model.select(session.id)
    #expect(model.windowTitle.full == "Vibe Manager › Before")

    var renamed = session
    renamed.name = "After"
    await repository.replace(with: [renamed])
    await model.reload()

    #expect(model.windowTitle.full == "Vibe Manager › After")
  }

  @Test("Under a multiple selection, the title names the session on screen")
  func multipleSelection() async throws {
    let first = WorkSession(name: "Alpha", updatedAt: Date(timeIntervalSince1970: 200))
    let second = WorkSession(name: "Beta", updatedAt: Date(timeIntervalSince1970: 100))
    let model = AppModel(repository: StubRepository(sessions: [first, second]))
    await model.load()
    model.select(first.id)

    model.selectFromList([first.id, second.id])

    #expect(model.hasMultipleSelection)
    let onScreen = try #require(model.selectedSession)
    #expect(model.windowTitle.full == "Vibe Manager › \(onScreen.name)")
  }

  @Test("Over a new session's draft, the title names the draft as its row does")
  func newSessionDraft() async throws {
    let shown = WorkSession(name: "Underneath")
    let repository = WorkspaceRepository(sessions: [shown])
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.load()
    model.select(shown.id)

    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    #expect(model.windowTitle.sessionName == draft.placeholderName)

    draft.draft.name = "Refonte"
    #expect(model.windowTitle.full == "Vibe Manager › Refonte")

    model.select(shown.id)
    #expect(model.windowTitle.full == "Vibe Manager › Underneath")
  }

  @Test("The application's name is the one the bundle gives")
  func applicationName() async {
    let session = WorkSession(name: "Alpha")
    let model = AppModel(repository: StubRepository(sessions: [session]))
    model.applicationName = "Vibe Manager Copy"
    await model.load()
    model.select(session.id)

    #expect(model.windowTitle.full == "Vibe Manager Copy › Alpha")
  }

  @Test("A name on several lines is said on one; a blank one leaves the application alone")
  func singleLine() {
    let title = WindowTitle(applicationName: "Vibe Manager", sessionName: "Refonte\nde l'API ")
    #expect(title.full == "Vibe Manager › Refonte de l'API")
    #expect(title.spoken == "Vibe Manager, Refonte de l'API")
    #expect(!title.spoken.contains("›"))

    let blank = WindowTitle(applicationName: "Vibe Manager", sessionName: "  ")
    #expect(blank.sessionName == nil)
    #expect(blank.full == "Vibe Manager")
  }
}

/// The toolbar gives an item the width it asks for, never less: the title asks for no more than
/// what the other items leave it.
@Suite("The window's title leaves the toolbar's buttons their room")
struct ToolbarTitleLayoutTests {
  /// The four buttons of a session's toolbar, measured side by side.
  private let buttons: CGFloat = 150

  @Test("Without a centred item, everything up to the buttons, held against the edge")
  func upToTheButtons() {
    let room = ToolbarTitleLayout.room(
      titleLeading: 152, windowWidth: 1180, detailLeading: 144, centredWidth: nil,
      trailingExtent: buttons)
    // 1180 − (8 + 150 + 8) − 152
    #expect(room == 862)
  }

  @Test("With no button after it, up to the edge")
  func noButtons() {
    let room = ToolbarTitleLayout.room(
      titleLeading: 152, windowWidth: 1180, detailLeading: 144, centredWidth: nil,
      trailingExtent: 0)
    #expect(room == 1020)
  }

  @Test("With a centred picker, up to the picker")
  func upToThePicker() {
    let room = ToolbarTitleLayout.room(
      titleLeading: 152, windowWidth: 1180, detailLeading: 144, centredWidth: 204,
      trailingExtent: buttons)
    // Centred right of the sidebar: (144 + 1180) / 2 − 102 = 560, less a space, less 152.
    #expect(room == 400)
  }

  @Test("In a narrow window, the picker pushed back by the buttons")
  func pickerPushedBack() {
    let room = ToolbarTitleLayout.room(
      titleLeading: 152, windowWidth: 640, detailLeading: 144, centredWidth: 204,
      trailingExtent: buttons)
    // 640 − 166 − 204 = 270, left of where it would be centred (290); less a space, less 152.
    #expect(room == 110)
  }

  @Test("Never less than nothing")
  func neverNegative() {
    let room = ToolbarTitleLayout.room(
      titleLeading: 300, windowWidth: 400, detailLeading: 0, centredWidth: 204,
      trailingExtent: buttons)
    #expect(room == 0)
  }

  @Test("Buttons never seen side by side are counted with a space between each")
  func estimatedExtent() {
    #expect(ToolbarTitleLayout.estimatedExtent(of: []) == 0)
    #expect(ToolbarTitleLayout.estimatedExtent(of: [36, 35, 41]) == 128)
  }

  @Test("Unmeasured, a wide window still gives the title the room for the application's name")
  func unmeasuredWideWindow() {
    // Waiting for the measurement at a fixed 80 pt hid the application's name and cut every
    // session's name short (#256).
    let room = ToolbarTitleLayout.fallbackRoom(detailWidth: 1040)
    #expect(room == 402)
    #expect(
      ToolbarTitleLayout.showsApplicationName(
        room: room, applicationWidth: 118, nameWidth: 180))
  }

  @Test("Unmeasured, a narrow window leaves the title enough of the session's name to read")
  func unmeasuredNarrowWindow() {
    #expect(
      ToolbarTitleLayout.fallbackRoom(detailWidth: 300) == ToolbarTitleLayout.minimumNameWidth)
    #expect(ToolbarTitleLayout.fallbackRoom(detailWidth: 0) == ToolbarTitleLayout.minimumNameWidth)
  }

  @Test("The application's name is shown when it fits with the whole name")
  func applicationNameWithWholeName() {
    #expect(
      ToolbarTitleLayout.showsApplicationName(room: 160, applicationWidth: 118, nameWidth: 40))
    #expect(
      !ToolbarTitleLayout.showsApplicationName(room: 157, applicationWidth: 118, nameWidth: 40))
  }

  @Test("A long name keeps the application's name while enough of the name can be read")
  func applicationNameWithLongName() {
    #expect(
      ToolbarTitleLayout.showsApplicationName(room: 198, applicationWidth: 118, nameWidth: 600))
    #expect(
      !ToolbarTitleLayout.showsApplicationName(room: 197, applicationWidth: 118, nameWidth: 600))
    #expect(
      !ToolbarTitleLayout.showsApplicationName(room: 0, applicationWidth: 118, nameWidth: 600))
  }
}
