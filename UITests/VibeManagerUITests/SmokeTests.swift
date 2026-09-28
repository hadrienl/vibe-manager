import XCTest

/// The nominal journey on the real, built application (#19): three sessions created, moved
/// between, noted, restarted and closed, the application quit and relaunched, and the sessions
/// found again. Every action goes through its keyboard shortcut; only the text fields of the New
/// Session sheet are clicked into, to type their values.
///
/// Not part of `Scripts/ci.sh`: a shared runner without a stable graphical session would fail pull
/// requests for nothing. The `ui-smoke` job runs it on `main` and on demand, and the release
/// checklist requires it to pass (see `docs/release-checklist.md`).
@MainActor
final class SmokeTests: XCTestCase {
  private var dataDirectory: URL!
  private var workDirectory: URL!
  private let suite = "com.hadrienl.VibeManager.smoke.\(UUID().uuidString)"

  override func setUp() async throws {
    continueAfterFailure = false
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeSmoke-\(UUID().uuidString.prefix(8))", isDirectory: true)
    dataDirectory = root.appendingPathComponent("Data", isDirectory: true)
    workDirectory = root.appendingPathComponent("Work", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    if let root = dataDirectory?.deletingLastPathComponent() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  /// In English unless told otherwise, whatever the language of the Mac that runs the test: the
  /// test finds its buttons and menus by their English titles.
  private func launch(language: String = "en", locale: String = "en_US") -> XCUIApplication {
    // `Scripts/clean-install-check.sh` points it at the notarized application it installed:
    // `TEST_RUNNER_VIBE_SMOKE_APP` reaches this process as `VIBE_SMOKE_APP`.
    let app =
      ProcessInfo.processInfo.environment["VIBE_SMOKE_APP"].map {
        XCUIApplication(url: URL(fileURLWithPath: $0))
      } ?? XCUIApplication()
    app.launchEnvironment = [
      "VIBE_DATA_DIRECTORY": dataDirectory.path,
      "VIBE_DEFAULTS_SUITE": suite,
      "VIBE_ENABLE_MOCK_AGENT": "only",
    ]
    // The launch step about Full Disk Access is not shown, whatever the build is signed as, and no
    // window state is restored.
    app.launchArguments += [
      "-permissions.fullDiskAccess.stepSuppressed", "YES",
      "-ApplePersistenceIgnoreState", "YES",
      "-AppleLanguages", "(\(language))",
      "-AppleLocale", locale,
    ]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
    return app
  }

  private func sessionRows(in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "session-row")
  }

  /// Waits for the rows of the four columns together (#80). On a failure, keeps what the
  /// interface showed and what it exposed to accessibility. Leaves In Progress selected, where
  /// launched sessions are: the shortcuts that follow select among the rows shown.
  private func expectSessionRows(
    _ expected: Int, in app: XCUIApplication, timeout: TimeInterval = 10
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    var found = 0
    repeat {
      found = ["todo", "waiting", "done", "doing"].reduce(0) { total, column in
        app.buttons["column-tab-\(column)"].click()
        return total + sessionRows(in: app).count
      }
      if found == expected { return }
      Thread.sleep(forTimeInterval: 0.5)
    } while Date() < deadline
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "Accessibility tree"
    tree.lifetime = .keepAlways
    add(tree)
    XCTAssertEqual(found, expected, "Sessions in the four columns together")
  }

  private func createSession(named name: String, isFirst: Bool, in app: XCUIApplication) {
    app.typeKey("n", modifierFlags: .command)
    let nameField = app.textFields["new-session-name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 10))
    nameField.click()
    nameField.typeText(name)
    let folder = app.textFields["new-session-folder"]
    if isFirst {
      folder.click()
      folder.typeText(workDirectory.path)
    } else {
      // The folder of the previous session is proposed again, with its card (#39). The card is
      // waited for: the field is only filled once the recent folders have been looked at.
      XCTAssertTrue(app.buttons["new-session-recent-folder-0"].waitForExistence(timeout: 10))
      let filled = NSPredicate(format: "value == %@", workDirectory.path)
      let proposed = expectation(for: filled, evaluatedWith: folder)
      wait(for: [proposed], timeout: 10)
    }
    // ⌘↩ creates from anywhere in the form.
    app.typeKey(.return, modifierFlags: .command)
    XCTAssertTrue(
      nameField.waitForNonExistence(timeout: 20), "The sheet did not close for \(name)")
    // The sheet closes at Create, before the session is stored (#117): its placeholder stands for
    // it until its agent has started. Only then is the session made, and the next one begun.
    let placeholder = app.descendants(matching: .any)
      .matching(identifier: "session-creation-placeholder").firstMatch
    XCTAssertTrue(
      placeholder.waitForNonExistence(timeout: 20), "\(name) was never done being created")
  }

  func testNominalJourneyFromTheKeyboard() throws {
    var app = launch()

    for index in 1...3 {
      createSession(named: "Smoke \(index)", isFirst: index == 1, in: app)
    }
    expectSessionRows(3, in: app)
    // The mock agent writes a transcript: its session opens as a conversation (#38), once the
    // application has learnt that it can, which the picker's appearing says. ⌥⌘T shows the
    // terminal.
    let showTerminal = app.radioButtons["Terminal"]
    XCTAssertTrue(showTerminal.waitForExistence(timeout: 10))
    if (showTerminal.value as? NSNumber)?.intValue != 1 {
      app.typeKey("t", modifierFlags: [.command, .option])
    }
    let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 10))

    // Moving between sessions and zones.
    app.typeKey(.downArrow, modifierFlags: [.command, .option])
    app.typeKey(.upArrow, modifierFlags: [.command, .option])
    app.typeKey("1", modifierFlags: .command)
    app.typeKey("3", modifierFlags: .command)
    app.typeKey("1", modifierFlags: [.command, .option])
    app.typeKey("2", modifierFlags: [.command, .option])

    // Open Quickly: a session found by its title and opened with Return; Escape closes it too.
    app.typeKey("p", modifierFlags: .command)
    let quickOpen = app.textFields["quick-open-field"]
    XCTAssertTrue(quickOpen.waitForExistence(timeout: 5))
    app.typeText("Smoke 2")
    let result = app.descendants(matching: .any).matching(identifier: "quick-open-row").firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(quickOpen.waitForNonExistence(timeout: 5))
    app.typeKey("p", modifierFlags: .command)
    XCTAssertTrue(quickOpen.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(quickOpen.waitForNonExistence(timeout: 5))

    // A note, typed after Edit Notes, and handed back with Escape.
    app.typeKey("n", modifierFlags: [.command, .option])
    let notes = app.textViews["notes-editor"]
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    app.typeText("Smoke note")
    app.typeKey(.escape, modifierFlags: [])

    // The mock agent says its piece and exits: the session is closed, and Restart starts it again.
    app.typeKey("r", modifierFlags: [.command, .control])
    // A session without a conversation to resume asks before sending its summary.
    let restart = app.buttons["Restart"]
    if restart.waitForExistence(timeout: 5) {
      app.typeKey(.return, modifierFlags: .command)
    }

    // Close Session, ⇧⌘W (#165): with a running agent it asks first, and Return confirms.
    app.typeKey("w", modifierFlags: [.command, .shift])
    let confirm = app.sheets.buttons.firstMatch
    if confirm.waitForExistence(timeout: 3) {
      app.typeKey(.return, modifierFlags: [])
    }

    // Quit, with whatever still runs stopped, and launch again.
    app.typeKey("q", modifierFlags: .command)
    let stopAll = app.buttons["Stop All"]
    if stopAll.waitForExistence(timeout: 3) {
      stopAll.click()
    }
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))

    app = launch()
    expectSessionRows(3, in: app, timeout: 20)
    app.terminate()
  }

  /// The application in French: a button of the window, a tab of the sidebar, a command of the
  /// Help menu — whose own title comes from macOS — and the New Session sheet.
  /// Several sessions selected in the sidebar, one command for all of them (#77).
  func testArchivingASelection() throws {
    let app = launch()
    for index in 1...3 {
      createSession(named: "Batch \(index)", isFirst: index == 1, in: app)
    }
    expectSessionRows(3, in: app)
    let column = ["doing", "todo", "waiting", "done"].first { column in
      app.buttons["column-tab-\(column)"].click()
      return sessionRows(in: app).count == 3
    }
    XCTAssertNotNil(column, "The three sessions share a column")

    let rows = sessionRows(in: app)
    rows.element(boundBy: 0).click()
    XCUIElement.perform(withKeyModifiers: .command) {
      rows.element(boundBy: 1).click()
      rows.element(boundBy: 2).click()
    }
    let session = app.menuBars.menuBarItems["Session"]
    session.click()
    XCTAssertTrue(app.menuItems["Archive 3 Sessions…"].waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])

    // The keyboard gone to the terminal, the commands are back on the session on screen.
    let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
    if terminal.waitForExistence(timeout: 5) {
      terminal.click()
      session.click()
      XCTAssertTrue(app.menuItems["Archive…"].waitForExistence(timeout: 5))
      app.typeKey(.escape, modifierFlags: [])
    }

    rows.element(boundBy: 0).click()
    XCUIElement.perform(withKeyModifiers: .shift) {
      rows.element(boundBy: 2).click()
    }
    rows.element(boundBy: 1).rightClick()
    // The context menu's item, not the Session menu's one of the same title (#77).
    let archive = app.outlines["session-list"].menuItems["Archive 3 Sessions…"]
    XCTAssertTrue(archive.waitForExistence(timeout: 5))
    archive.click()
    // The dialog's button: the Touch Bar shows one of the same title, which cannot be clicked.
    let confirm = app.sheets.buttons["Archive"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "One question for the three sessions")
    confirm.click()

    expectSessionRows(0, in: app, timeout: 20)
    XCTAssertTrue(app.buttons["archived-sessions"].label.contains("3"))
    app.terminate()
  }

  func testTheInterfaceSpeaksFrench() throws {
    let app = launch(language: "fr", locale: "fr_FR")
    XCTAssertTrue(app.buttons["Nouvelle session"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["column-tab-todo"].label.hasPrefix("À faire"))
    XCTAssertTrue(app.buttons["column-tab-doing"].label.hasPrefix("En cours"))

    app.menuBars.menuBarItems["Aide"].click()
    XCTAssertTrue(app.menuBars.menuItems["Exporter les diagnostics…"].waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])

    app.typeKey("n", modifierFlags: .command)
    let create = app.buttons["new-session-create"]
    XCTAssertTrue(create.waitForExistence(timeout: 10))
    XCTAssertEqual(create.label, "Créer et lancer")
    XCTAssertTrue(app.staticTexts["Dossier de travail"].exists)
    app.typeKey(.escape, modifierFlags: [])
    app.terminate()
  }

  func testExportDiagnosticsShowsTheWholeFileFirst() throws {
    let app = launch()
    app.menuBars.menuBarItems["Help"].click()
    app.menuBars.menuItems["Export Diagnostics…"].click()
    let preview = app.descendants(matching: .any).matching(identifier: "diagnostics-preview")
      .firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["diagnostics-save"].exists)
    app.typeKey(.escape, modifierFlags: [])
    app.terminate()
  }
}
