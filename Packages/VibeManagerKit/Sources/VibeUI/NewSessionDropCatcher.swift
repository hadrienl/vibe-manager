import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// What a drag of files over the new session's draft does where it hovers.
enum NewSessionDropHover: Equatable {
  /// The files join the prompt.
  case attaching
  /// One folder over the working folder: the session works in it.
  case choosingFolder
  /// A template's prompt is its own: no file joins it.
  case refusingTemplate

  var isAccepting: Bool { self != .refusingTemplate }
}

/// The new session's draft, as one place to drop files on: they join its prompt, as Attach
/// Files… does.
///
/// A transparent AppKit view laid over the whole draft. A SwiftUI drop destination could not be
/// it: AppKit gives a drag to the frontmost view under the pointer registered for the drag's
/// types, and the draft — drawn over the session selected — had none but the prompt's text view,
/// which typed the path where it was let go. Laid in front, this view wins every drag that
/// carries a file, the prompt's field included, so a file joins the prompt the same way wherever
/// it is let go — but a folder over the working folder, which becomes the session's. An image with no
/// file, or a file its source promises, joins it too, received into a temporary folder: the agent
/// reads it as the session starts. A text or a web address meets none of its types and goes where
/// it went before. AppKit finds a drag's destination without asking `hitTest(_:)`: the
/// view answers no click, and VoiceOver does not see it.
struct NewSessionDropCatcher: NSViewRepresentable {
  /// What the files of a drag would do at a point of the draft, its origin at the top left:
  /// `nil` while nothing may be dropped at all.
  let hover: @MainActor (_ files: [URL], _ location: CGPoint) -> NewSessionDropHover?
  let hovering: @MainActor (NewSessionDropHover?) -> Void
  let dropped: @MainActor ([URL], NewSessionDropHover) -> Void
  /// So many files are on their way, from a drop just made.
  let receiving: @MainActor (Int) -> Void
  /// One delivery of them: what came, and whether something could not be read.
  let received: @MainActor ([URL], Bool) -> Void

  static let fileTypes: [NSPasteboard.PasteboardType] =
    [
      .fileURL, .init("NSFilenamesPboardType"),
      .tiff, .init("NeXT TIFF v4.0 pasteboard type"), .png, .init("Apple PNG pasteboard type"),
      .init(UTType.jpeg.identifier), .init(UTType.heic.identifier),
      .init(UTType.gif.identifier), .init(UTType.webP.identifier), .init(UTType.image.identifier),
    ] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

  func makeNSView(context _: Context) -> CatcherView {
    let view = CatcherView()
    view.catcher = self
    return view
  }

  func updateNSView(_ view: CatcherView, context _: Context) {
    view.catcher = self
  }

  /// The files a drag carries, in its order: only files of the disk, never a web address.
  static func files(on pasteboard: NSPasteboard) -> [URL] {
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    return (urls as? [URL] ?? []).filter(\.isFileURL)
  }

  /// Whether a drag brings a file that is not on the disk yet: promised, or an image.
  static func carriesFileToReceive(on pasteboard: NSPasteboard) -> Bool {
    !promises(on: pasteboard).isEmpty || !images(on: pasteboard).isEmpty
  }

  private static func promises(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
    pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
      ?? []
  }

  /// The image of each element of the drag with no file of its own, in a format the agents read
  /// when it offers one.
  private static func images(
    on pasteboard: NSPasteboard
  ) -> [(item: NSPasteboardItem, type: NSPasteboard.PasteboardType, uti: UTType)] {
    let readable: [UTType] = [.png, .jpeg, .gif, .webP]
    return (pasteboard.pasteboardItems ?? []).compactMap { item in
      guard !item.types.contains(.fileURL) else { return nil }
      let offered = item.types.compactMap { type in
        UTType(type.rawValue).flatMap { $0.conforms(to: .image) ? (type, $0) : nil }
      }
      let best =
        offered.first { pair in readable.contains(where: pair.1.conforms(to:)) } ?? offered.first
      return best.map { (item, $0.0, $0.1) }
    }
  }

  private static func newFolder() -> URL? {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(CreateSession.receivedDropsFolder, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      return folder
    } catch {
      return nil
    }
  }

  /// A floating screenshot lives where the system deletes it behind the drop: a copy is joined.
  /// Any other file is the original, which the agent reads and edits.
  static func kept(_ file: URL) -> URL {
    guard file.path.contains("/TemporaryItems/"), let folder = newFolder() else { return file }
    let copy = folder.appendingPathComponent(file.lastPathComponent)
    return (try? FileManager.default.copyItem(at: file, to: copy)) == nil ? file : copy
  }

  /// Receives what a drag brings with no file of the disk, images first as `DropReader` does: a
  /// promise may fail where the bytes are there. `receiving` tells how many deliveries to expect,
  /// `received` is called once for each, on the main actor: an image is converted and written,
  /// and a promise delivered by its source, away from it, after the drop. A folder nothing came
  /// to is removed.
  func receiveFiles(on pasteboard: NSPasteboard) {
    // The bytes are read now: the drag's pasteboard does not outlive the drop.
    let offered = Self.images(on: pasteboard)
    let images = offered.compactMap { image in
      image.item.data(forType: image.type).map { (data: $0, type: image.uti) }
    }
    let promises = images.isEmpty ? Self.promises(on: pasteboard) : []
    guard !images.isEmpty || !promises.isEmpty, let folder = Self.newFolder() else {
      receiving(1)
      received([], true)
      return
    }
    let received = received
    if !images.isEmpty {
      receiving(1)
      let unreadable = images.count < offered.count
      Task.detached(priority: .userInitiated) {
        let written = Self.write(images, into: folder)
        await received(written.files, written.failed || unreadable)
      }
      return
    }
    let deliveries = PromisedDeliveries(
      promises.reduce(0) { $0 + max($1.fileNames.count, 1) }, into: folder)
    receiving(deliveries.left)
    // Not on the main queue, as Apple advises: a source slow to write its file holds nothing up.
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    for promise in promises {
      promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) {
        @Sendable url, error in
        let file = error == nil ? url : nil
        Task { @MainActor in
          received(file.map { [$0] } ?? [], file == nil)
          deliveries.delivered(file)
        }
      }
    }
  }

  /// Each image in a format the agents read, written in `folder` — away from the main thread:
  /// converting a photo takes its time. The folder goes when none could be written.
  private nonisolated static func write(
    _ images: [(data: Data, type: UTType)], into folder: URL
  ) -> (files: [URL], failed: Bool) {
    var files: [URL] = []
    var failed = false
    for image in images {
      guard
        case .data(let bytes, let name) = DropReader.imageItem(
          image.data, type: image.type, suggestedName: nil)
      else {
        failed = true
        continue
      }
      let file = folder.appendingPathComponent(
        DropNaming.unique(name) { taken in
          files.contains { $0.lastPathComponent == taken }
        })
      if (try? bytes.write(to: file)) == nil { failed = true } else { files.append(file) }
    }
    if files.isEmpty { try? FileManager.default.removeItem(at: folder) }
    return (files, failed)
  }

  final class CatcherView: NSView {
    var catcher: NewSessionDropCatcher?
    /// The files of the drag going on, read once when it enters rather than at every move.
    private var files: [URL] = []
    /// No file of the disk, but a promised one or an image.
    private var receivesFile = false

    override init(frame: NSRect) {
      super.init(frame: frame)
      registerForDraggedTypes(NewSessionDropCatcher.fileTypes)
      setAccessibilityElement(false)
    }

    required init?(coder _: NSCoder) { nil }

    /// As SwiftUI measures the draft: from the top left.
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    private func hover(_ drag: any NSDraggingInfo) -> NewSessionDropHover? {
      guard !files.isEmpty || receivesFile else { return nil }
      return catcher?.hover(files, convert(drag.draggingLocation, from: nil))
    }

    private func propose(_ drag: any NSDraggingInfo) -> NSDragOperation {
      let hover = hover(drag)
      catcher?.hovering(hover)
      // No "+" on the pointer: the refusal is seen before letting go.
      return hover?.isAccepting == true ? .copy : []
    }

    override func draggingEntered(_ drag: any NSDraggingInfo) -> NSDragOperation {
      let pasteboard = drag.draggingPasteboard
      files = NewSessionDropCatcher.files(on: pasteboard)
      receivesFile = NewSessionDropCatcher.carriesFileToReceive(on: pasteboard)
      return propose(drag)
    }

    override func draggingUpdated(_ drag: any NSDraggingInfo) -> NSDragOperation {
      propose(drag)
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
      catcher?.hovering(nil)
    }

    override func prepareForDragOperation(_ drag: any NSDraggingInfo) -> Bool {
      hover(drag)?.isAccepting == true
    }

    override func performDragOperation(_ drag: any NSDraggingInfo) -> Bool {
      catcher?.hovering(nil)
      guard let hover = hover(drag), hover.isAccepting else { return false }
      if !files.isEmpty {
        catcher?.dropped(files.map(NewSessionDropCatcher.kept), hover)
      }
      if receivesFile {
        catcher?.receiveFiles(on: drag.draggingPasteboard)
      }
      return true
    }

    override func draggingEnded(_: any NSDraggingInfo) {
      catcher?.hovering(nil)
      files = []
      receivesFile = false
    }
  }
}

/// The deliveries a drop's promises still owe: the folder they are received in goes when none
/// brought a file.
@MainActor
private final class PromisedDeliveries {
  private(set) var left: Int
  private let folder: URL
  private var receivedAny = false

  init(_ count: Int, into folder: URL) {
    left = count
    self.folder = folder
  }

  func delivered(_ file: URL?) {
    left -= 1
    receivedAny = receivedAny || file != nil
    if left == 0, !receivedAny { try? FileManager.default.removeItem(at: folder) }
  }
}
