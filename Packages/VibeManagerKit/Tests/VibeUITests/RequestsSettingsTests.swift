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

/// Settings › Notifications (#154, #313): how the requests are signalled, and the avatars that
/// present them on a page reached from it.
@Suite("Settings › Notifications", .timeLimit(.minutes(2)))
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
    model.settingsPage = .requests
    return model
  }

  /// The settings on `page`, in a window as wide as the page needs, as the settings window
  /// widens to it.
  private func window(
    _ model: AppModel, page: SettingsPage, language: String = "en", dark: Bool = false
  ) -> (NSWindow, NSHostingController<AnyView>) {
    model.settingsPage = page
    let host = NSHostingController(
      rootView: AnyView(
        SettingsView(model: model).environment(\.locale, Locale(identifier: language))))
    let size = NSSize(
      width: SettingsSplitView.sidebarWidth + page.detailWidth,
      height: SettingsSplitView.idealHeight)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = host
    host.view.appearance = window.appearance
    window.setContentSize(size)
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

  @Test("Notifications is a page of the sidebar, and the avatars a page reached from it")
  func pages() async {
    let model = await workspace()
    let sidebar = SettingsSidebarContent(model: model, permissions: nil)
    let pages = sidebar.groups.flatMap(\.entries).map(\.page)
    #expect(pages.contains(.requests))
    #expect(!pages.contains(.avatars))
    #expect(SettingsPage.avatars.parent == .requests)
    #expect(SettingsPage.avatars.sidebarPage == .requests)
    #expect(sidebar.shown(.avatars) == .avatars)
    #expect(NSImage(systemSymbolName: SettingsPage.requests.symbolName, accessibilityDescription: nil) != nil)
  }

  @Test("The page and the avatars are named in French")
  func french() {
    #expect(Localization.string(SettingsPage.requests.title, in: "fr") == "Notifications")
    #expect(Localization.string(SettingsPage.avatars.title, in: "fr") == "Avatars")
  }

  @Test("The sidebar is as wide as said")
  func sidebarWidth() async {
    let model = await workspace()
    let (window, host) = window(model, page: .requests)
    defer { window.close() }
    await settle(window, "the page of the alerts") { Self.switches(in: host.view).count == 4 }
    let sidebar = Self.descendants(of: host.view).compactMap { $0 as? NSOutlineView }
      .compactMap(\.enclosingScrollView).map(\.frame.width)
    #expect(sidebar.first.map { $0 >= SettingsSplitView.sidebarWidth - 1 } == true, "\(sidebar)")
  }

  @Test("Manage Avatars… turns to the page of the avatars")
  func manageAvatars() async {
    let model = await workspace()
    SignallingSettings(model: model).manageAvatars()
    #expect(model.settingsPage == .avatars)
  }

  @Test("The window shows the avatars, then the alerts again")
  func avatarsThenAlerts() async {
    let model = await workspace()
    let (window, host) = window(model, page: .requests)
    defer { window.close() }
    await settle(window, "the page of the alerts") { Self.switches(in: host.view).count == 4 }
    model.settingsPage = .avatars
    // The page of the avatars: its list beside the sidebar's, and no switch of the alerts.
    await settle(window, "the page of the avatars") {
      Self.descendants(of: host.view).filter { $0 is NSTableView }.count == 2
        && Self.switches(in: host.view).isEmpty
    }
    model.settingsPage = .requests
    await settle(window, "the page of the alerts again") {
      Self.switches(in: host.view).count == 4
    }
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
    let (window, host) = window(model, page: .requests)
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

  /// Each page, in a window as wide as the sidebar and the page need: nothing is cut on the
  /// sides. The captures are written when `VIBE_SETTINGS_SNAPSHOTS` names a folder.
  @Test(
    "Each page is whole in the window it gets",
    arguments: [SettingsPage.requests, .avatars], ["fr", "en"])
  func pageIsWhole(page: SettingsPage, language: String) async throws {
    for dark in [false, true] {
      let model = await workspace()
      let (window, host) = window(model, page: page, language: language, dark: dark)
      defer { window.close() }
      let view = host.view
      await settle(window, "the page \(page)") {
        switch page {
        case .avatars:
          // The sidebar's list, and the avatars'.
          Self.descendants(of: view).filter { $0 is NSTableView }.count == 2
        default: Self.switches(in: view).count == 4
        }
      }
      let bounds = view.bounds.insetBy(dx: -0.5, dy: -0.5)
      let cut = Self.drawnViews(in: view).filter {
        $0.minX < bounds.minX || $0.maxX > bounds.maxX
      }
      #expect(cut.isEmpty, "Views outside the window of \(view.bounds.size): \(cut)")

      if let folder = ProcessInfo.processInfo.environment["VIBE_SETTINGS_SNAPSHOTS"] {
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: folder).appendingPathComponent(
            "settings-\(page)-\(language)-\(dark ? "dark" : "light").png"))
      }
    }
  }

  // MARK: - Looking into the window

  /// The switches of the page, from the top: SwiftUI draws most controls of a form itself, but
  /// its switches are AppKit's.
  private static func switches(in view: NSView) -> [NSControl] {
    descendants(of: view)
      .compactMap { $0 as? NSControl }
      .filter { String(describing: type(of: $0)).contains("Switch") }
      .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
  }

  /// The frames, in the window's view, of the AppKit controls the settings draw with. What a
  /// scroll view holds may extend past it: the scroll view is what is seen.
  private static func drawnViews(in root: NSView) -> [CGRect] {
    descendants(of: root)
      .filter { $0 is NSControl || $0 is NSScrollView }
      .filter { $0.enclosingScrollView == nil || $0 is NSScrollView }
      .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 && $0.frame.height > 0 }
      .map { $0.convert($0.bounds, to: root) }
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}
