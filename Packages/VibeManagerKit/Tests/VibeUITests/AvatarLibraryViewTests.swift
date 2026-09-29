import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import VibeApplication
import VibeLocalizationTesting

@testable import VibeUI

/// Faces a capture can tell apart: a round face of the colour given, with eyes and a mouth that
/// change with the expression.
private enum PageFaces {
  static func png(_ color: NSColor, _ expression: AvatarExpression = .neutral) -> Data {
    let size = 96
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
    NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 84, height: 84)).fill()
    NSColor.black.setFill()
    let eyeHeight: CGFloat = expression == .eyesClosed ? 2 : 13
    NSBezierPath(ovalIn: NSRect(x: 30, y: 52, width: 10, height: eyeHeight)).fill()
    NSBezierPath(ovalIn: NSRect(x: 56, y: 52, width: 10, height: eyeHeight)).fill()
    let mouthHeight: CGFloat = expression == .mouthOpen ? 14 : 5
    NSBezierPath(
      roundedRect: NSRect(x: 34, y: 26, width: 28, height: mouthHeight), xRadius: 3, yRadius: 3
    )
    .fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:]) ?? Data()
  }

  static func sprites(_ color: NSColor, missing: Set<AvatarExpression> = [])
    -> [AvatarExpression: Data]
  {
    Dictionary(
      uniqueKeysWithValues: AvatarExpression.allCases.filter { !missing.contains($0) }.map {
        ($0, png(color, $0))
      })
  }

  static func avatar(
    _ name: String, _ color: NSColor, source: AvatarManifest.Source = .imported,
    description: String? = nil, missing: Set<AvatarExpression> = []
  ) -> AvatarSpriteSet {
    AvatarSpriteSet(
      manifest: AvatarManifest(
        name: name, source: source, provider: source == .generated ? "codex" : nil,
        description: description, createdAt: Date(timeIntervalSince1970: 1_790_380_800)),
      sprites: sprites(color, missing: missing))
  }
}

/// A sheet "drawn" by the agent becomes an owl's faces; nothing else is read.
private struct PageProcessing: AvatarImageProcessing {
  func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  {
    PageFaces.sprites(.systemBrown).filter { expressions.contains($0.key) }
  }
  func sprite(fromImage data: Data, as expression: AvatarExpression, matching reference: Data?)
    throws -> Data
  { PageFaces.png(.systemBrown, expression) }
  func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int) {
    throw AvatarProblem.archiveUnreadable
  }
  func archive(_ avatar: AvatarSpriteSet) throws -> Data { Data() }
}

/// An agent the test holds until it lets it go, and whose answer it decides.
private final class HeldGenerator: AvatarGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var isHeld = false
  private var answer: Result<Data, AvatarGenerationError> = .success(Data("sheet".utf8))

  func hold() { lock.withLock { isHeld = true } }
  func release() { lock.withLock { isHeld = false } }
  func answer(_ answer: Result<Data, AvatarGenerationError>) {
    lock.withLock { self.answer = answer }
  }

  func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    while lock.withLock({ isHeld }) {
      if Task.isCancelled { throw AvatarGenerationError.failed("cancelled") }
      await Task.yield()
    }
    return try lock.withLock { answer }.get()
  }
}

private struct PageGenerators: AvatarGeneratorResolving {
  let generator: HeldGenerator

  func options() async -> [AvatarGeneratorOption] {
    [
      AvatarGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("codex"), displayName: "Codex"),
        unavailability: nil, generator: generator),
      AvatarGeneratorOption(
        descriptor: AgentDescriptor(id: AgentProviderID("claude"), displayName: "Claude Code"),
        unavailability: .notCapable, generator: nil),
    ]
  }
}

/// A state of the page, as the design shows it.
enum AvatarPageState: String, CaseIterable, Sendable {
  /// Three avatars, the one in use selected, the card folded.
  case list
  /// The card that makes a new avatar, unfolded.
  case card
  /// A generation under way, selected.
  case generation
  /// A draft to check, which lacks an expression.
  case candidate
  /// A generation that failed, selected.
  case failure
}

/// Settings › Requests › Avatars (#154): each state of the page, whole at 900 × 700 points.
@Suite("Settings › Requests › Avatars", .timeLimit(.minutes(5)))
@MainActor
struct AvatarLibraryViewTests {
  private let generator = HeldGenerator()
  private static let owl =
    "Une chouette brune à grosses lunettes rondes, dessin plat, contours épais."

  /// The library of the design: the default avatar, a fox in use, a robot.
  private func library(drafts: [AvatarSpriteSet] = []) async -> AvatarLibraryModel {
    _ = NSApplication.shared
    let library = InMemoryAvatarLibrary(
      defaultAvatar: PageFaces.avatar("Default", .systemBlue, source: .bundled),
      kept: [
        PageFaces.avatar(
          "Renard roux à écharpe bleue", .systemOrange, source: .generated,
          description: "Un renard roux, style autocollant, avec une écharpe bleue."),
        PageFaces.avatar("Robot rétro menthe", .systemMint),
      ])
    let fox = try? await library.entries().first { $0.manifest?.name.hasPrefix("Renard") == true }
    if let fox { try? await library.setInUse(fox.id) }
    for draft in drafts {
      _ = try? await library.saveDraft(draft, basedOn: nil)
    }
    let avatars = AvatarLibraryModel(
      workshop: AvatarWorkshop(processing: PageProcessing()), library: library,
      generators: PageGenerators(generator: generator))
    await avatars.load()
    await avatars.refreshOptions()
    return avatars
  }

  /// The library in `state`, and whether the card is unfolded.
  private func prepare(_ state: AvatarPageState) async -> (AvatarLibraryModel, Bool) {
    switch state {
    case .list:
      return (await library(), false)
    case .card:
      let avatars = await library()
      avatars.description = Self.owl
      return (avatars, true)
    case .generation:
      let avatars = await library()
      generator.hold()
      avatars.description = Self.owl
      avatars.generate()
      await waitUntil("the generation under way") { avatars.work != nil }
      return (avatars, false)
    case .candidate:
      let avatars = await library(drafts: [
        PageFaces.avatar(
          "Chouette à lunettes rondes", .systemBrown, source: .generated, description: Self.owl,
          missing: [.worried])
      ])
      return (avatars, false)
    case .failure:
      let avatars = await library()
      generator.answer(
        .failure(
          .rejected(.wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1024, height: 1024))))
      avatars.description = Self.owl
      avatars.generate()
      await waitUntil("the failed generation") { avatars.failures.count == 1 }
      return (avatars, false)
    }
  }

  /// The page alone, at the size of the pages of Settings › Requests.
  private func window(
    _ avatars: AvatarLibraryModel, isCreating: Bool, language: String, dark: Bool
  ) -> (NSWindow, NSHostingController<AnyView>) {
    let size = RequestsSettingsView.pageSize
    let host = NSHostingController(
      rootView: AnyView(
        AvatarLibraryView(avatars: avatars, isCreating: isCreating)
          .frame(width: size.width, height: size.height)
          .environment(\.locale, Locale(identifier: language))))
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

  /// Lays the page out until `condition` holds: SwiftUI builds a page over several passes.
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

  // MARK: - The words of the page

  @Test("The default avatar is used, duplicated and exported, never renamed nor deleted")
  func actionsOfTheDefaultAvatar() {
    let entry = AvatarLibraryEntry(
      id: .default, state: .kept, manifest: nil, addedAt: .distantPast)
    let actions = AvatarLibraryPresentation.actions(
      for: entry, inUse: .stored(UUID()), canCreate: true, canRename: false)
    #expect(actions.offered == [.use, .duplicate, .export])
    #expect(actions.enabled(.use))
    let inUse = AvatarLibraryPresentation.actions(
      for: entry, inUse: .default, canCreate: false, canRename: false)
    #expect(!inUse.enabled(.use))
    #expect(!inUse.enabled(.duplicate))
  }

  @Test("A kept avatar has every action; a draft is only renamed and discarded")
  func actionsOfKeptAvatarsAndDrafts() {
    let manifest = AvatarManifest(name: "Robot", source: .imported)
    let kept = AvatarLibraryEntry(
      id: .stored(UUID()), state: .kept, manifest: manifest, addedAt: .now)
    #expect(
      AvatarLibraryPresentation.actions(
        for: kept, inUse: .default, canCreate: true, canRename: true
      ).offered == [.use, .rename, .duplicate, .export, .delete])
    let draft = AvatarLibraryEntry(
      id: .stored(UUID()), state: .draft(basedOn: nil), manifest: manifest, addedAt: .now)
    #expect(
      AvatarLibraryPresentation.actions(
        for: draft, inUse: .default, canCreate: true, canRename: true
      ).offered == [.rename, .delete])
    var unreadable = kept
    unreadable.problem = .unreadable
    let actions = AvatarLibraryPresentation.actions(
      for: unreadable, inUse: .default, canCreate: true, canRename: true)
    #expect(!actions.enabled(.use))
    #expect(!actions.enabled(.export))
    #expect(!actions.enabled(.duplicate))
    #expect(actions.enabled(.delete))
  }

  @Test("A generation that redraws an avatar is shown on its row, not on a row of its own")
  func listedJobs() {
    let kept = AvatarID.stored(UUID())
    func job(_ kind: AvatarLibraryModel.Work, _ destination: AvatarLibraryModel.Job.Destination)
      -> AvatarLibraryModel.Job
    {
      AvatarLibraryModel.Job(
        id: UUID(), kind: kind, destination: destination, description: "",
        provider: AgentProviderID("codex"), startedAt: .now, phase: .running)
    }
    let new = job(.wholeSet, .newDraft(basedOn: nil))
    let redraw = job(.expression(.pleased), .newDraft(basedOn: kept))
    var failed = job(.wholeSet, .newDraft(basedOn: nil))
    failed.phase = .failed(.noImage, at: .now)
    let listed = AvatarLibraryPresentation.listedJobs([new, redraw, failed])
    #expect(listed.map(\.id) == [new.id, failed.id])
  }

  @Test("The header says how many avatars, and their size, in each language")
  func summary() {
    let french = Localization.string(
      AvatarLibraryPresentation.summary(
        count: 3, byteCount: 9_800_000, locale: Locale(identifier: "fr")), in: "fr")
    #expect(french.hasPrefix("3 avatars · 9,8"))
    let one = Localization.string(
      AvatarLibraryPresentation.summary(count: 1, byteCount: 0, locale: Locale(identifier: "en")),
      in: "en")
    #expect(one.hasPrefix("1 avatar · "))
  }

  /// AppKit gives a drop to the view under the pointer, or to one of its ancestors: the page's own
  /// destination is beside the list's table, not around it. The table must take files itself.
  @Test("A file dropped on the list is taken by the list, and around it by the page")
  func dropsReachThePage() async throws {
    let avatars = await library()
    let (window, host) = window(avatars, isCreating: false, language: "en", dark: false)
    defer { window.close() }
    await settle(window, "the list") { Self.table(in: host.view) != nil }
    let table = try #require(Self.table(in: host.view))
    // A file dragged from the Finder carries its URL, never the type of what it holds: the rows
    // take file URLs, and read only the zip archives.
    let board = NSPasteboard(name: NSPasteboard.Name("avatar-drop-\(UUID())"))
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/Avatar - Robot.zip") as NSURL])
    #expect(board.types?.contains(NSPasteboard.PasteboardType(UTType.zip.identifier)) == false)
    #expect(table.registeredDraggedTypes.contains(.fileURL))
    // Around the list — its header, its footer — the page's destination takes the rest.
    let page = Self.descendants(of: host.view).filter {
      $0 !== table && $0.registeredDraggedTypes.contains(NSPasteboard.PasteboardType("public.item"))
    }
    #expect(page.contains { $0.frame.width >= AvatarLibraryView.listWidth - 0.5 })
  }

  @Test("Each row has its avatar's face, read once, and gone with the avatar")
  func thumbnails() async throws {
    let avatars = await library()
    // Not at launch: only once a page shows the list.
    #expect(avatars.thumbnails.isEmpty)
    avatars.showThumbnails()
    await avatars.thumbnailTask?.value
    #expect(Set(avatars.thumbnails.keys) == Set(avatars.entries.map(\.id)))
    let robot = try #require(avatars.entries.last)
    await avatars.remove(robot.id)
    await avatars.thumbnailTask?.value
    #expect(avatars.thumbnails[robot.id] == nil)
    #expect(Set(avatars.thumbnails.keys) == Set(avatars.entries.map(\.id)))
  }

  @Test("The avatar selected again keeps the images already made")
  func sameImagesWhenSelectedAgain() async throws {
    let avatars = await library()
    let image = try #require(avatars.selectedImages[.neutral])
    await avatars.refresh()
    await avatars.select(avatars.selection)
    #expect(avatars.selectedImages[.neutral] === image)
  }

  // MARK: - The keyboard

  private static func key(
    _ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
    in window: NSWindow
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
  }

  private static func press(
    _ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
    in window: NSWindow
  ) {
    guard let down = key(characters, code: code, modifiers, in: window) else { return }
    window.sendEvent(down)
  }

  @Test("Return and ⌘⌫ typed in the description are the text's: nothing is renamed nor deleted")
  func typingInTheDescription() async throws {
    let avatars = await library()
    let robot = try #require(avatars.entries.last)
    await avatars.select(.avatar(robot.id))
    avatars.description = "Une chouette"
    let (window, host) = window(avatars, isCreating: true, language: "fr", dark: false)
    defer { window.close() }
    var editor: NSTextView?
    await settle(window, "the description") {
      editor = Self.descendants(of: host.view).lazy.compactMap { $0 as? NSTextView }.first
      return editor != nil
    }
    let text = try #require(editor)
    await settle(window, "the keyboard in the description") {
      window.firstResponder === text || window.makeFirstResponder(text)
    }
    text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
    Self.press("\r", code: 36, in: window)
    await settle(window, "the new line") { avatars.description.contains("\n") }
    Self.press("\u{8}", code: 51, .command, in: window)
    // Neither the alert that renames nor the question that deletes: the text had the keys.
    for _ in 0..<20 {
      window.contentView?.layoutSubtreeIfNeeded()
      await Task.yield()
    }
    #expect(window.attachedSheet == nil)
    #expect(avatars.entry(robot.id) != nil)
  }

  @Test("In the list, Return renames the avatar selected, and ⌘⌫ asks before deleting it")
  func keysOfTheList() async throws {
    let avatars = await library()
    let robot = try #require(avatars.entries.last)
    await avatars.select(.avatar(robot.id))
    let (window, host) = window(avatars, isCreating: false, language: "fr", dark: false)
    defer { window.close() }
    await settle(window, "the list") { Self.table(in: host.view) != nil }
    let table = try #require(Self.table(in: host.view))
    await settle(window, "the keyboard in the list") {
      window.firstResponder === table || window.makeFirstResponder(table)
    }
    Self.press("\r", code: 36, in: window)
    await settle(window, "the alert that renames") { window.attachedSheet != nil }
    let rename = try #require(window.attachedSheet)
    let field = Self.descendants(of: rename.contentView ?? NSView()).lazy
      .compactMap { $0 as? NSTextField }.first { $0.isEditable }
    #expect(field?.stringValue == "Robot rétro menthe")
    window.endSheet(rename)
    await settle(window, "the alert closed") { window.attachedSheet == nil }

    await settle(window, "the keyboard in the list again") {
      window.firstResponder === table || window.makeFirstResponder(table)
    }
    Self.press("\u{8}", code: 51, .command, in: window)
    await settle(window, "the question that deletes") { window.attachedSheet != nil }
    // Asked, not done.
    #expect(avatars.entry(robot.id) != nil)
    if let sheet = window.attachedSheet { window.endSheet(sheet) }
  }

  @Test("What the list selects is selected at once, and shown once read")
  func choose() async throws {
    let avatars = await library()
    let robot = try #require(avatars.entries.last)
    avatars.choose(.avatar(robot.id))
    #expect(avatars.selection == .avatar(robot.id))
    await waitUntil("the robot shown") {
      avatars.selectedAvatar?.manifest.name == "Robot rétro menthe"
    }
  }

  @Test("The rows take only zip archives, and none while a new avatar cannot be made")
  func rowsTakeArchivesOnly() async throws {
    #expect(AvatarLibraryPresentation.droppedTypes == [.fileURL])
    let avatars = await library()
    generator.hold()
    avatars.description = Self.owl
    avatars.generate()
    await waitUntil("the generation under way") { avatars.work != nil }
    let view = AvatarLibraryView(avatars: avatars)
    let archive = FileManager.default.temporaryDirectory
      .appendingPathComponent("Avatar - \(UUID().uuidString).zip")
    try Data("PK".utf8).write(to: archive)
    defer { try? FileManager.default.removeItem(at: archive) }
    // During a generation: not even read.
    view.dropFiles([NSItemProvider(object: archive as NSURL)])
    for _ in 0..<20 { await Task.yield() }
    #expect(!avatars.isImporting)
    #expect(avatars.problem == nil)
    avatars.cancel()
    generator.release()

    // Another file is left alone; the archive is read — and refused here, being none.
    let text = archive.deletingPathExtension().appendingPathExtension("txt")
    try Data("PK".utf8).write(to: text)
    defer { try? FileManager.default.removeItem(at: text) }
    view.dropFiles([NSItemProvider(object: text as NSURL)])
    for _ in 0..<20 { await Task.yield() }
    #expect(avatars.problem == nil)
    view.dropFiles([NSItemProvider(object: archive as NSURL)])
    await waitUntil("the archive read") { avatars.problem == .archive(.archiveUnreadable) }
  }

  @Test("Edit the Description… does not replace, unasked, a description being written")
  func replacesDescription() {
    #expect(!AvatarLibraryPresentation.replacesDescription("", with: "Un hibou"))
    #expect(!AvatarLibraryPresentation.replacesDescription(" Un hibou\n", with: "Un hibou"))
    #expect(AvatarLibraryPresentation.replacesDescription("Un renard", with: "Un hibou"))
  }

  @Test("Only a zip archive is taken from what is dropped")
  func droppedArchive() {
    let text = URL(fileURLWithPath: "/tmp/notes.txt")
    let zip = URL(fileURLWithPath: "/tmp/Avatar - Robot.ZIP")
    #expect(AvatarLibraryPresentation.archive(in: [text, zip]) == zip)
    #expect(AvatarLibraryPresentation.archive(in: [text]) == nil)
  }

  @Test("The card is greyed out, with the reason, while a generation is under way")
  func cardGreyedDuringAGeneration() async {
    let avatars = await library()
    #expect(AvatarLibraryPresentation.creationUnavailability(avatars) == nil)
    generator.hold()
    avatars.description = Self.owl
    avatars.generate()
    await waitUntil("the generation under way") { avatars.work != nil }
    let reason = AvatarLibraryPresentation.creationUnavailability(avatars)
    #expect(
      reason.map { Localization.string($0, in: "fr") }
        == "Disponible à la fin de la génération en cours")
    avatars.cancel()
    generator.release()
    #expect(AvatarLibraryPresentation.creationUnavailability(avatars) == nil)
  }

  @Test("The card is greyed out, with the reason, when the library is full")
  func cardGreyedWhenFull() async throws {
    let avatars = await library(
      drafts: (0..<(AvatarLibraryRules.maximumCount - 2)).map {
        PageFaces.avatar("Copie \($0)", .systemGray)
      })
    #expect(!avatars.canCreate)
    let reason = try #require(AvatarLibraryPresentation.creationUnavailability(avatars))
    #expect(
      Localization.string(reason, in: "fr")
        == Localization.string(AvatarPresentation.message(for: .limitReached), in: "fr"))
  }

  // MARK: - The page, drawn

  /// Each state of the design, in each language: nothing is cut, and the preview holds whole in
  /// the page. The captures are written when `VIBE_SETTINGS_SNAPSHOTS` names a folder.
  @Test(
    "Each state of the page is whole at 900 × 700 points",
    arguments: AvatarPageState.allCases, ["fr", "en"])
  func stateIsWhole(state: AvatarPageState, language: String) async throws {
    let folder = ProcessInfo.processInfo.environment["VIBE_SETTINGS_SNAPSHOTS"]
    let appearances = folder != nil && language == "fr" ? [false, true] : [false]
    for dark in appearances {
      let (avatars, isCreating) = await prepare(state)
      defer {
        avatars.cancel()
        generator.release()
      }
      let (window, host) = window(
        avatars, isCreating: isCreating, language: language, dark: dark)
      defer { window.close() }
      let view = host.view
      // The rows: the avatars, the generation that is not one yet, and the card.
      let rows =
        avatars.entries.count + AvatarLibraryPresentation.listedJobs(avatars.jobs).count + 1
      await settle(window, "the rows of \(state)") {
        Self.table(in: view)?.numberOfRows == rows && Self.preview(in: view) != nil
          && avatars.thumbnails.count == avatars.entries.count
          && (state != .card || Self.descendants(of: view).contains { $0 is NSTextView })
      }
      switch state {
      case .list, .card:
        #expect(avatars.selection == .avatar(avatars.inUse))
      case .generation:
        #expect(avatars.selection == avatars.work.map { .job($0.id) })
        #expect(AvatarLibraryPresentation.creationUnavailability(avatars) != nil)
      case .candidate:
        #expect(avatars.selectedEntry?.isDraft == true)
        #expect(avatars.selectedAvatar?.missingExpressions == [.worried])
      case .failure:
        #expect(avatars.selection == avatars.failures.first.map { .job($0.id) })
      }

      // Nothing outside the page, and the preview whole: it scrolls only as a last resort.
      let bounds = view.bounds.insetBy(dx: -0.5, dy: -0.5)
      let cut = Self.drawnViews(in: view).filter { !bounds.contains($0) }
      #expect(cut.isEmpty, "Views outside the page of \(view.bounds.size): \(cut)")
      let preview = try #require(Self.preview(in: view))
      let content = preview.documentView?.frame.height ?? .infinity
      #expect(
        content <= preview.contentView.bounds.height + 0.5,
        "The preview needs \(content) points, and shows \(preview.contentView.bounds.height).")
      // The list keeps its 520 points, less its margins.
      let table = try #require(Self.table(in: view))
      #expect(table.frame.width <= AvatarLibraryView.listWidth - 40 + 0.5)

      if let folder {
        try Self.capture(
          view, window: window,
          to: URL(fileURLWithPath: folder).appendingPathComponent(
            "avatars-\(state.rawValue)-\(language)-\(dark ? "dark" : "light").png"))
      }
    }
  }

  // MARK: - Looking into the page

  private static func table(in view: NSView) -> NSTableView? {
    descendants(of: view).lazy.compactMap { $0 as? NSTableView }.first
  }

  /// The scroll view of the preview: the one right of the list.
  private static func preview(in view: NSView) -> NSScrollView? {
    descendants(of: view).lazy.compactMap { $0 as? NSScrollView }
      .first { $0.convert($0.bounds, to: view).minX > AvatarLibraryView.listWidth - 1 }
  }

  /// The frames, in the page, of what is drawn outside a scroll view.
  private static func drawnViews(in view: NSView) -> [CGRect] {
    descendants(of: view)
      .filter { $0.enclosingScrollView == nil || $0 is NSScrollView }
      .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 && $0.frame.height > 0 }
      .map { $0.convert($0.bounds, to: view) }
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  /// The page, its layers over the window's background.
  private static func capture(_ view: NSView, window: NSWindow, to url: URL) throws {
    let layer = try #require(view.layer)
    let scale = window.backingScaleFactor
    let image = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
        pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    image.size = view.bounds.size
    let context = try #require(NSGraphicsContext(bitmapImageRep: image))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: view.bounds.size).fill()
    }
    if view.isFlipped {
      context.cgContext.translateBy(x: 0, y: view.bounds.height)
      context.cgContext.scaleBy(x: 1, y: -1)
    }
    layer.render(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let data = try #require(image.representation(using: .png, properties: [:]))
    try data.write(to: url)
  }
}
