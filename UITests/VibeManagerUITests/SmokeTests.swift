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
    if isFirst {
      // ⌘↩ creates from anywhere in the form.
      app.typeKey(.return, modifierFlags: .command)
    } else {
      // Return creates from the name too, as from the prompt: it only selected the name.
      nameField.typeKey(.return, modifierFlags: [])
    }
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

    // The keyboard gone to the terminal, the commands are back on the session on screen. The mock
    // agent's session opens as a conversation (#177), whose empty area takes no keyboard: shown
    // as a terminal first.
    let asTerminal = app.radioButtons["Terminal"]
    if asTerminal.waitForExistence(timeout: 5) { asTerminal.click() }
    let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
    if terminal.waitForExistence(timeout: 5) {
      terminal.click()
      session.click()
      // "Archive…" while the mock agent runs, "Archive" once it has exited (#115).
      let single = app.menuItems.matching(
        NSPredicate(format: "title == 'Archive' OR title == 'Archive…'")
      ).firstMatch
      XCTAssertTrue(single.waitForExistence(timeout: 5))
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

  /// ⌃⌘A archives a session where nothing runs at once, and pressed again archives the one that
  /// took its place (#115): no question, no tolerance.
  func testArchivingInABurstFromTheKeyboard() throws {
    let app = launch()
    for index in 1...2 {
      createSession(named: "Burst \(index)", isFirst: index == 1, in: app)
    }
    expectSessionRows(2, in: app)

    // Both agents stopped first: ⇧⌘W, confirmed when one still runs.
    for _ in 1...2 {
      app.typeKey("w", modifierFlags: [.command, .shift])
      let confirm = app.sheets.buttons["Close Session"]
      if confirm.waitForExistence(timeout: 3) {
        confirm.click()
      }
      app.typeKey(.downArrow, modifierFlags: [.command, .option])
    }
    let session = app.menuBars.menuBarItems["Session"]
    session.click()
    XCTAssertTrue(app.menuItems["Archive"].waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])

    app.typeKey("a", modifierFlags: [.command, .control])
    XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "Archive asked")
    expectSessionRows(1, in: app)

    app.typeKey("a", modifierFlags: [.command, .control])
    XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "Archive asked")
    expectSessionRows(0, in: app)
    XCTAssertTrue(app.buttons["archived-sessions"].label.contains("2"))
    app.terminate()
  }

  /// The toolbar's buttons against the window's right edge, in a view with a picker centred and in
  /// one without, and the title as wide as its text rather than a placeholder (#256): the title
  /// drawn in the toolbar once left them wherever its width put them.
  func testTheToolbarKeepsItsButtonsAgainstTheRightEdge() throws {
    let app = launch()
    createSession(named: "Toolbar layout check", isFirst: true, in: app)
    expectSessionRows(1, in: app)
    let window = app.windows.firstMatch
    let title = app.descendants(matching: .any).matching(identifier: "window-title").firstMatch
    let inspector = app.toolbars.buttons.matching(
      NSPredicate(format: "label == 'Show Context' OR label == 'Hide Context'")
    ).firstMatch

    // A session shown as a conversation: its picker is centred in the toolbar.
    XCTAssertTrue(app.radioButtons["Terminal"].waitForExistence(timeout: 10))
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.label, "Vibe Manager, Toolbar layout check")
    XCTAssertTrue(inspector.waitForExistence(timeout: 5))
    let withPicker = inspector.frame.maxX
    XCTAssertLessThan(window.frame.maxX - withPicker, 24, "The buttons are away from the edge")
    XCTAssertGreaterThan(title.frame.width, 100, "The title is held to a placeholder width")

    // A new session's draft: nothing centred.
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.textFields["new-session-name"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.radioButtons["Terminal"].waitForNonExistence(timeout: 5))
    let settled = NSPredicate { _, _ in abs(inspector.frame.maxX - withPicker) < 1 }
    let stays = expectation(for: settled, evaluatedWith: nil)
    wait(for: [stays], timeout: 5)
    XCTAssertGreaterThan(title.frame.width, 80, "The title is held to a placeholder width")
    app.typeKey(.escape, modifierFlags: [])
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

  /// The main screens audited by XCTest, so that a view added later cannot lose what the
  /// application does for accessibility unnoticed (#233): the sidebar and a conversation, a new
  /// session's draft, and the settings. An issue the audit raises fails the test unless it is one
  /// of the exceptions below, each with the reason it stands — most of them the ticket that fixes
  /// it.
  func testTheMainScreensPassTheAccessibilityAudit() throws {
    // Every issue of every screen is reported, not only the first.
    continueAfterFailure = true
    let app = launch()
    createSession(named: "Audit", isFirst: true, in: app)
    expectSessionRows(1, in: app)
    // The mock agent's session opens as a conversation (#38): its picker says it can.
    XCTAssertTrue(app.radioButtons["Terminal"].waitForExistence(timeout: 10))
    try audit(app, "Sidebar and conversation")

    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.textFields["new-session-name"].waitForExistence(timeout: 10))
    try audit(app, "New session draft")
    app.typeKey(.escape, modifierFlags: [])

    app.typeKey(",", modifierFlags: .command)
    let settingsOpen = expectation(
      for: NSPredicate { _, _ in app.windows.count > 1 }, evaluatedWith: nil)
    wait(for: [settingsOpen], timeout: 10)
    try audit(app, "Settings")
    // A tab of the toolbar, or a row of a sidebar: whatever carries the tab's title is clicked.
    for tab in ["Badges", "Updates", "Requests"] {
      let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", tab))
        .firstMatch
      guard item.waitForExistence(timeout: 5) else {
        XCTFail("No \(tab) tab in the settings")
        continue
      }
      item.click()
      try audit(app, "Settings, \(tab)")
    }
    app.terminate()
  }

  /// An issue the audit may raise without failing the test, and why.
  private struct AuditException {
    let type: XCUIAccessibilityAuditType
    /// The issue's description, or a part of it; any when nil.
    var issue: String? = nil
    /// The kinds of element it may be raised on; any when empty.
    var elements: [XCUIElement.ElementType] = []
    /// A part of the element's identifier or label; any when nil, none at all when empty.
    var element: String? = nil
    let reason: String

    func covers(_ raised: XCUIAccessibilityAuditIssue) -> Bool {
      guard raised.auditType == type else { return false }
      if let issue, !raised.compactDescription.contains(issue) { return false }
      if !elements.isEmpty {
        guard let kind = raised.element?.elementType, elements.contains(kind) else { return false }
      }
      if let element {
        let names = [raised.element?.identifier ?? "", raised.element?.label ?? ""]
        if element.isEmpty {
          return names.allSatisfy(\.isEmpty)
        }
        return names.contains { $0.contains(element) }
      }
      return true
    }
  }

  /// What the audit raises today and may go on raising, each with its reason. The fixes in flight
  /// are named by their ticket: once one lands, its exception goes.
  private static let auditExceptions: [AuditException] = [
    AuditException(
      type: .contrast, elements: [.staticText],
      reason: """
        Secondary text and the colours of states: #231 makes the states' colours legible. The \
        system's secondary styles are measured by the audit without the vibrancy macOS gives \
        them over the sidebar's and the settings' materials.
        """),
    AuditException(
      type: .sufficientElementDescription, elements: [.group, .other], element: "",
      reason: "SwiftUI's containers: they gather controls, and are not controls themselves."),
    AuditException(
      type: .sufficientElementDescription, issue: "Unknown role", elements: [.other],
      reason: """
        The symbols and colours of the Badges settings are views without a button's role: #232 \
        names them, #230 makes them reachable from the keyboard.
        """),
    AuditException(
      type: .sufficientElementDescription, elements: [.touchBar],
      reason: "The Touch Bar macOS gives the window: none of its items is the application's."),
    AuditException(
      type: .sufficientElementDescription, elements: [.textField], element: "new-session-name",
      reason: """
        A new session's name has a placeholder and no label: found by this audit, given one by \
        #328.
        """),
    AuditException(
      type: .sufficientElementDescription, elements: [.popUpButton], element: "emoji & symbols",
      reason: "The Emoji & Symbols button macOS puts in a text field: the system's, not ours."),
    AuditException(
      type: .action, elements: [.popUpButton, .menuButton],
      reason: """
        SwiftUI's pickers and menus open with AXShowMenu; the audit looks for AXPress, which a \
        pop-up button does not need.
        """),
    AuditException(
      type: .parentChild,
      reason: """
        Raised without an element on a new session's draft, so it cannot be pinned down here: \
        looked into by #328.
        """),
  ]

  private static func name(of type: XCUIAccessibilityAuditType) -> String {
    let names: [(XCUIAccessibilityAuditType, String)] = [
      (.contrast, "contrast"), (.elementDetection, "elementDetection"),
      (.hitRegion, "hitRegion"), (.sufficientElementDescription, "sufficientElementDescription"),
      (.action, "action"), (.parentChild, "parentChild"),
    ]
    return names.first { type.contains($0.0) }?.1 ?? "type \(type.rawValue)"
  }

  /// Audits what the application shows now. Every issue is written to the log, the ones let
  /// through included, so that the list of exceptions can be read from a run.
  private func audit(_ app: XCUIApplication, _ screen: String) throws {
    var raised: [String] = []
    try app.performAccessibilityAudit(for: .all) { issue in
      let element =
        issue.element.map { "\($0.elementType) '\($0.identifier)' '\($0.label)'" } ?? "-"
      let text = "\(Self.name(of: issue.auditType)) \(issue.compactDescription) — \(element)"
      let exception = Self.auditExceptions.first { $0.covers(issue) }
      raised.append((exception == nil ? "FAIL " : "OK   ") + text)
      print("[accessibility-audit] \(screen): \(raised.last ?? "")")
      return exception != nil
    }
    let report = XCTAttachment(string: raised.joined(separator: "\n"))
    report.name = "Accessibility audit: \(screen)"
    report.lifetime = .keepAlways
    add(report)
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
