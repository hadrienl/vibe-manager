import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeBrowser
import VibeLocalizationTesting

@testable import VibeUI

/// Images a test can tell apart on a capture: a face of the colour given.
private enum Faces {
  static func png(_ color: NSColor) -> Data {
    let size = 64
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return Data() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 56, height: 56)).fill()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: 20, y: 34, width: 7, height: 9)).fill()
    NSBezierPath(ovalIn: NSRect(x: 37, y: 34, width: 7, height: 9)).fill()
    NSBezierPath(rect: NSRect(x: 22, y: 18, width: 20, height: 4)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:]) ?? Data()
  }

  static func avatar(
    _ name: String, _ color: NSColor, source: AvatarManifest.Source = .imported
  ) -> AvatarSpriteSet {
    let image = png(color)
    return AvatarSpriteSet(
      manifest: AvatarManifest(name: name, source: source),
      sprites: Dictionary(uniqueKeysWithValues: AvatarExpression.allCases.map { ($0, image) }))
  }
}

/// Nothing is drawn nor read here: the pages only show what the library holds.
private struct NoProcessing: AvatarImageProcessing {
  func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  { throw AvatarProblem.archiveUnreadable }
  func sprite(fromImage data: Data, as expression: AvatarExpression, matching reference: Data?)
    throws -> Data
  { throw AvatarProblem.archiveUnreadable }
  func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int) {
    throw AvatarProblem.archiveUnreadable
  }
  func archive(_ avatar: AvatarSpriteSet) throws -> Data { Data() }
}

/// A system that refuses the application's notifications.
@MainActor
private final class RefusedNotifier: RequestNotifying {
  func post(_ notification: RequestNotification) {}
  func remove(_ ids: [AgentRequestID]) {}
  func setBadge(_ count: Int?) {}
  func isAuthorized() async -> Bool? { false }
}

/// Settings › Requests (#154): one tab for the requests and their avatars, in two pages of the
/// same size.
@Suite("Settings › Requests", .timeLimit(.minutes(2)))
@MainActor
struct RequestsSettingsTests {
  /// A workspace with the floating panel and a library of three avatars — the default one, a fox
  /// in use, a robot — and a draft.
  private func workspace(panelEnabled: Bool = true) async -> AppModel {
    _ = NSApplication.shared
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: BrowserWorkspace())
    let panel = FloatingRequestPanelModel(preferences: InMemoryFloatingPanelPreferences())
    panel.isEnabled = panelEnabled
    model.floatingPanel = panel
    let library = InMemoryAvatarLibrary(
      defaultAvatar: Faces.avatar("Default", .systemBlue, source: .bundled),
      kept: [
        Faces.avatar("Renard roux à écharpe bleue", .systemOrange),
        Faces.avatar("Robot rétro menthe", .systemMint),
      ])
    let fox = try? await library.entries().first { $0.manifest?.name.hasPrefix("Renard") == true }
    if let fox { try? await library.setInUse(fox.id) }
    _ = try? await library.saveDraft(Faces.avatar("Chouette", .systemBrown), basedOn: nil)
    let avatars = AvatarLibraryModel(
      workshop: AvatarWorkshop(processing: NoProcessing()), library: library, generators: nil)
    await avatars.load()
    model.avatars = avatars
    model.settingsTab = .requests
    return model
  }

  /// The settings, in a window of the least size they accept, as the settings window shows them.
  private func window(
    _ model: AppModel, language: String = "en", dark: Bool = false
  ) -> (NSWindow, NSHostingController<AnyView>) {
    let host = NSHostingController(
      rootView: AnyView(
        SettingsView(model: model).environment(\.locale, Locale(identifier: language))))
    let least = host.sizeThatFits(in: .zero)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: least), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = host
    // Given to the view as well: drawn outside a window on screen, the tab view would otherwise
    // draw its part in the light appearance.
    host.view.appearance = window.appearance
    window.setContentSize(least)
    return (window, host)
  }

  /// Lays the window out until `condition` holds: SwiftUI builds a page over several passes.
  @discardableResult
  private func settle(
    _ window: NSWindow, _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    until condition: @MainActor () -> Bool
  ) async -> Bool {
    await waitUntil(what, sourceLocation: sourceLocation) {
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return condition()
    }
  }

  @Test("The tab has Privacy's hand no more, and Avatar is no longer a tab of its own")
  func tabs() {
    #expect(SettingsTab.requests.symbolName == "person.bubble")
    #expect(SettingsTab.privacy.symbolName == "hand.raised")
    #expect(SettingsTab.allCases.count == 9)
    #expect(!SettingsTab.allCases.map(\.rawValue).contains("avatar"))
    #expect(NSImage(systemSymbolName: "person.bubble", accessibilityDescription: nil) != nil)
  }

  @Test("The tab and its pages are named in French")
  func french() {
    #expect(Localization.string(SettingsTab.requests.title, in: "fr") == "Demandes")
    #expect(Localization.string(RequestsPane.signalling.title, in: "fr") == "Signalement")
    #expect(Localization.string(RequestsPane.avatars.title, in: "fr") == "Avatars")
    #expect(Localization.string(RequestsPane.signalling.title, in: "en") == "Alerts")
  }

  @Test("Both pages have the same size: the window does not jump from one to the other")
  func pagesHaveTheSameSize() async {
    let model = await workspace()
    var sizes: [RequestsPane: CGSize] = [:]
    for pane in RequestsPane.allCases {
      model.requestsPane = pane
      let host = NSHostingController(rootView: SettingsView(model: model))
      sizes[pane] = host.sizeThatFits(in: .zero)
    }
    #expect(sizes[.signalling] == sizes[.avatars])
    let width = sizes[.signalling]?.width ?? 0
    #expect(width >= RequestsSettingsView.pageSize.width)
    #expect(width >= SettingsView.formWidth)
  }

  @Test("The segmented control turns the pages, and the page shown is the model's")
  func segmentsTurnThePages() async throws {
    let model = await workspace()
    let (window, host) = window(model)
    defer { window.close() }
    let segments = try #require(
      await findView(in: window, "the segmented control") { (control: NSSegmentedControl) in
        control.segmentCount == 2
      })
    #expect(segments.selectedSegment == 0)
    await settle(window, "the page of the alerts") { Self.switches(in: host.view).count == 4 }

    segments.selectedSegment = 1
    _ = segments.sendAction(segments.action, to: segments.target)
    #expect(model.requestsPane == .avatars)
    // The page of the avatars: its list, and no switch of the alerts.
    await settle(window, "the page of the avatars") {
      Self.descendants(of: host.view).contains { $0 is NSTableView }
        && Self.switches(in: host.view).count < 4
    }

    model.requestsPane = .signalling
    await settle(window, "the page of the alerts again") {
      segments.selectedSegment == 0 && Self.switches(in: host.view).count == 4
    }
  }

  @Test("Manage Avatars… turns to the page of the avatars")
  func manageAvatars() async {
    let model = await workspace()
    SignallingSettings(model: model).manageAvatars()
    #expect(model.requestsPane == .avatars)
  }

  @Test("The Avatar row offers the avatars kept, never a draft, and changes the one in use")
  func avatarRowChangesTheAvatarInUse() async throws {
    let model = await workspace()
    let avatars = try #require(model.avatars)
    let row = AvatarInUseRow(avatars: avatars) {}
    #expect(avatars.entries.contains { $0.isDraft })
    #expect(row.choices.first?.id == .default)
    #expect(
      row.choices.dropFirst().map(AvatarLibraryModel.name(of:)) == [
        "Renard roux à écharpe bleue", "Robot rétro menthe",
      ])
    let fox = try #require(row.choices.first { $0.manifest?.name.hasPrefix("Renard") == true })
    #expect(row.inUse.wrappedValue == fox.id)
    let foxImage = avatars.inUseImages[.neutral]?.tiffRepresentation
    #expect(foxImage != nil)

    let robot = try #require(row.choices.last)
    row.inUse.wrappedValue = robot.id
    await waitUntil("the robot in use") { avatars.inUse == robot.id }
    // The panel shows it at once: the images in use are the robot's.
    await waitUntil("the robot's images") {
      avatars.inUseImages[.neutral]?.tiffRepresentation != foxImage
    }
    #expect(row.inUse.wrappedValue == robot.id)
  }

  @Test("The notifications are greyed out, with the reason, while the floating panel is on")
  func notificationsGreyedWhilePanelIsOn() async throws {
    let model = await workspace(panelEnabled: true)
    let settings = SignallingSettings(model: model)
    #expect(settings.notificationsAreReplaced)
    let (window, host) = window(model)
    defer { window.close() }
    // From the top: the floating panel, the notifications, the Dock badge, the palette.
    await settle(window, "the switches of the page") { Self.switches(in: host.view).count == 4 }
    #expect(Self.switches(in: host.view).map(\.isEnabled) == [true, false, true, true])

    model.floatingPanel?.isEnabled = false
    #expect(!settings.notificationsAreReplaced)
    await settle(window, "the notifications back") {
      Self.switches(in: host.view).map(\.isEnabled) == [true, true, true, true]
    }
  }

  /// The other tall state of the alerts: the panel off, the notifications on but refused by the
  /// system, whose line "Open System Settings…" replaces the reason of the greyed notifications.
  @Test("The alerts are whole with the notifications refused", arguments: ["fr", "en"])
  func alertsWholeWithNotificationsRefused(language: String) async throws {
    let model = await workspace(panelEnabled: false)
    model.notifiesRequests = true
    model.requestNotifier = RefusedNotifier()
    let (window, host) = window(model, language: language)
    defer { window.close() }
    let view = host.view
    await settle(window, "the refused notifications") {
      Self.switches(in: view).map(\.isEnabled) == [true, true, true, true]
        && (Self.descendants(of: view).lazy.compactMap { $0 as? NSScrollView }.first?
          .documentView?.frame.height ?? 0) > 0
    }
    let form = try #require(
      Self.descendants(of: view).lazy.compactMap { $0 as? NSScrollView }.first)
    let content = form.documentView?.frame.height ?? .infinity
    #expect(
      content <= form.contentView.bounds.height + 0.5,
      "The form needs \(content) points, and shows \(form.contentView.bounds.height).")
  }

  /// Each page, in the least window the settings accept: nothing is cut on any side. The
  /// captures are written when `VIBE_SETTINGS_SNAPSHOTS` names a folder.
  @Test(
    "Each page is whole in the least window the settings accept",
    arguments: RequestsPane.allCases, ["fr", "en"])
  func pageIsWhole(pane: RequestsPane, language: String) async throws {
    for dark in [false, true] {
      let model = await workspace()
      model.requestsPane = pane
      let (window, host) = window(model, language: language, dark: dark)
      defer { window.close() }
      let view = host.view
      await settle(window, "the page \(pane)") {
        switch pane {
        case .signalling: Self.switches(in: view).count == 4
        case .avatars: Self.descendants(of: view).contains { $0 is NSTableView }
        }
      }
      #expect(window.contentLayoutRect.width >= RequestsSettingsView.pageSize.width)

      let tabView = try #require(
        Self.descendants(of: view).lazy.compactMap { $0 as? NSTabView }.first)
      let bounds = tabView.bounds.insetBy(dx: -0.5, dy: -0.5)
      let cut = Self.drawnViews(in: tabView).filter { !bounds.contains($0) }
      #expect(cut.isEmpty, "Views outside the tab of \(tabView.bounds.size): \(cut)")
      // The alerts are whole, the palette included: their form has nothing under the fold.
      if pane == .signalling {
        let form = try #require(
          Self.descendants(of: view).lazy.compactMap { $0 as? NSScrollView }.first)
        let content = form.documentView?.frame.height ?? .infinity
        #expect(
          content <= form.contentView.bounds.height + 0.5,
          "The form needs \(content) points, and shows \(form.contentView.bounds.height).")
      }

      if let folder = ProcessInfo.processInfo.environment["VIBE_SETTINGS_SNAPSHOTS"] {
        // The page alone, its layers over the window's background: drawn off screen by
        // `cacheDisplay`, what the page leaves transparent came out white, and the segmented
        // control of the dark captures vanished.
        let content = try #require(tabView.subviews.first { !($0 is NSSegmentedControl) })
        let layer = try #require(content.layer)
        let scale = window.backingScaleFactor
        let image = try #require(
          NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * scale),
            pixelsHigh: Int(content.bounds.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        image.size = content.bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: image))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
          NSColor.windowBackgroundColor.setFill()
          NSRect(origin: .zero, size: content.bounds.size).fill()
        }
        if content.isFlipped {
          context.cgContext.translateBy(x: 0, y: content.bounds.height)
          context.cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: folder).appendingPathComponent(
            "settings-requests-\(pane.rawValue)-\(language)-\(dark ? "dark" : "light").png"))
      }
    }
  }

  // MARK: - Looking into the window

  private func findView<Found: NSView>(
    in window: NSWindow, _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    matching: @escaping (Found) -> Bool
  ) async -> Found? {
    var found: Found?
    await settle(window, what, sourceLocation: sourceLocation) {
      found = window.contentView.flatMap { root in
        Self.descendants(of: root).lazy.compactMap { $0 as? Found }.first(where: matching)
      }
      return found != nil
    }
    return found
  }

  /// The switches of the page, from the top: SwiftUI draws most controls of a form itself, but
  /// its switches are AppKit's.
  private static func switches(in view: NSView) -> [NSControl] {
    descendants(of: view)
      .compactMap { $0 as? NSControl }
      .filter { String(describing: type(of: $0)).contains("Switch") }
      .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
  }

  /// The frames, in the tab view, of the page and of the AppKit controls it draws with. What a
  /// scroll view holds may extend past it: the scroll view is what is seen.
  private static func drawnViews(in tabView: NSTabView) -> [CGRect] {
    descendants(of: tabView)
      .filter { $0.superview === tabView || $0 is NSControl || $0 is NSScrollView }
      .filter { $0.enclosingScrollView == nil || $0 is NSScrollView }
      .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 && $0.frame.height > 0 }
      .map { $0.convert($0.bounds, to: tabView) }
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}
