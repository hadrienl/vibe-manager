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

  private func launch() -> XCUIApplication {
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
    // The launch step about Full Disk Access is answered, and no window state is restored.
    app.launchArguments += [
      "-permissions.fullDiskAccess.stepDismissed.v1", "YES",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
    return app
  }

  private func sessionRows(in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "session-row")
  }

  /// Waits for the rows of both tabs together: the mock agent says its piece and exits, so a
  /// session may be in Closed as soon as it is created. On a failure, keeps what the interface
  /// showed and what it exposed to accessibility. Leaves the Closed tab selected, where the
  /// sessions are: the shortcuts that follow select among the rows shown.
  private func expectSessionRows(
    _ expected: Int, in app: XCUIApplication, timeout: TimeInterval = 10
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    var found = 0
    repeat {
      found = ["Active", "Closed"].reduce(0) { total, scope in
        app.radioButtons[scope].click()
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
    XCTAssertEqual(found, expected, "Sessions in Active and Closed together")
  }

  private func createSession(named name: String, in app: XCUIApplication) {
    app.typeKey("n", modifierFlags: .command)
    let nameField = app.textFields["new-session-name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 10))
    nameField.click()
    nameField.typeText(name)
    let folder = app.textFields["new-session-folder"]
    folder.click()
    folder.typeText(workDirectory.path)
    // ⌘↩ creates from anywhere in the form.
    app.typeKey(.return, modifierFlags: .command)
    XCTAssertTrue(
      nameField.waitForNonExistence(timeout: 20), "The sheet did not close for \(name)")
  }

  func testNominalJourneyFromTheKeyboard() throws {
    var app = launch()

    for index in 1...3 {
      createSession(named: "Smoke \(index)", in: app)
    }
    expectSessionRows(3, in: app)
    let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 10))

    // Moving between sessions and zones.
    app.typeKey(.downArrow, modifierFlags: [.command, .option])
    app.typeKey(.upArrow, modifierFlags: [.command, .option])
    app.typeKey("1", modifierFlags: .command)
    app.typeKey("3", modifierFlags: .command)
    app.typeKey("1", modifierFlags: [.command, .option])
    app.typeKey("2", modifierFlags: [.command, .option])

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

    // Close Session: with a running agent it asks first, and Return confirms.
    app.typeKey("w", modifierFlags: .command)
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
