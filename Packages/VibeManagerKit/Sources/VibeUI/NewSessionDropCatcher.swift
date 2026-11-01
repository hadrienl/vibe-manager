import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

  /// Whether a drag with no file of the disk brings one all the same: promised, or an image.
  static func carriesFileToReceive(on pasteboard: NSPasteboard) -> Bool {
    !promises(on: pasteboard).isEmpty || image(on: pasteboard) != nil
  }

  private static func promises(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
    pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
      ?? []
  }

  private static func image(on pasteboard: NSPasteboard) -> (NSPasteboard.PasteboardType, UTType)? {
    for type in pasteboard.types ?? [] {
      if let uti = UTType(type.rawValue), uti.conforms(to: .image) { return (type, uti) }
    }
    return nil
  }

  /// Receives what a drag brings without a file of the disk, each file handed over as it arrives:
  /// a promise is kept by its source, which delivers it after the drop.
  static func receiveFiles(
    on pasteboard: NSPasteboard, delivering deliver: @escaping @MainActor ([URL]) -> Void
  ) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerDrops", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    guard
      (try? FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])) != nil
    else { return }
    let promises = promises(on: pasteboard)
    if !promises.isEmpty {
      for promise in promises {
        promise.receivePromisedFiles(atDestination: folder, operationQueue: .main) { url, error in
          guard error == nil else { return }
          MainActor.assumeIsolated { deliver([url]) }
        }
      }
      return
    }
    guard let (type, uti) = image(on: pasteboard), let data = pasteboard.data(forType: type),
      case .data(let bytes, let name) = DropReader.imageItem(data, type: uti, suggestedName: nil)
    else { return }
    let file = folder.appendingPathComponent(name)
    guard (try? bytes.write(to: file)) != nil else { return }
    deliver([file])
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
      receivesFile = files.isEmpty && NewSessionDropCatcher.carriesFileToReceive(on: pasteboard)
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
      if receivesFile {
        let dropped = catcher?.dropped
        NewSessionDropCatcher.receiveFiles(on: drag.draggingPasteboard) { files in
          dropped?(files, hover)
        }
      } else {
        catcher?.dropped(files, hover)
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
