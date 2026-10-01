import AppKit
import SwiftUI

/// What a drag of files over the new session's draft shows while it hovers.
enum NewSessionDropHover: Equatable {
  case accepting
  /// A template's prompt is its own: no file joins it.
  case refusingTemplate
}

/// The new session's draft, as one place to drop files on: they join its prompt, as Attach
/// Files… does.
///
/// A transparent AppKit view laid over the whole draft. A SwiftUI drop destination could not be
/// it: AppKit gives a drag to the frontmost view under the pointer registered for the drag's
/// types, and the draft — drawn over the session selected — had none but the prompt's text view,
/// which typed the path where it was let go. Laid in front, this view wins every drag that
/// carries a file, the prompt's field included, so a file joins the prompt the same way wherever
/// it is let go. A text, a web address or an image with no file meets none of its types and goes
/// where it went before. AppKit finds a drag's destination without asking `hitTest(_:)`: the
/// view answers no click, and VoiceOver does not see it.
struct NewSessionDropCatcher: NSViewRepresentable {
  /// The hover a drag of files would get now: `nil` while nothing may be dropped at all.
  let hover: @MainActor () -> NewSessionDropHover?
  let hovering: @MainActor (NewSessionDropHover?) -> Void
  let dropped: @MainActor ([URL]) -> Void

  static let fileTypes: [NSPasteboard.PasteboardType] = [
    .fileURL, .init("NSFilenamesPboardType"),
  ]

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.catcher = self
    return view
  }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.catcher = self
  }

  /// The files a drag carries, in its order: only files of the disk, never a web address.
  static func files(on pasteboard: NSPasteboard) -> [URL] {
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    return (urls as? [URL] ?? []).filter(\.isFileURL)
  }

  final class CatcherView: NSView {
    var catcher: NewSessionDropCatcher?

    override init(frame: NSRect) {
      super.init(frame: frame)
      registerForDraggedTypes(NewSessionDropCatcher.fileTypes)
      setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func propose(_ drag: any NSDraggingInfo) -> NSDragOperation {
      let hover =
        NewSessionDropCatcher.files(on: drag.draggingPasteboard).isEmpty
        ? nil : catcher?.hover()
      catcher?.hovering(hover)
      // No "+" on the pointer: the refusal is seen before letting go.
      return hover == .accepting ? .copy : []
    }

    override func draggingEntered(_ drag: any NSDraggingInfo) -> NSDragOperation {
      propose(drag)
    }

    override func draggingUpdated(_ drag: any NSDraggingInfo) -> NSDragOperation {
      propose(drag)
    }

    override func draggingExited(_ drag: (any NSDraggingInfo)?) {
      catcher?.hovering(nil)
    }

    override func prepareForDragOperation(_ drag: any NSDraggingInfo) -> Bool {
      catcher?.hover() == .accepting
    }

    override func performDragOperation(_ drag: any NSDraggingInfo) -> Bool {
      catcher?.hovering(nil)
      let files = NewSessionDropCatcher.files(on: drag.draggingPasteboard)
      guard catcher?.hover() == .accepting, !files.isEmpty else { return false }
      catcher?.dropped(files)
      return true
    }

    override func draggingEnded(_ drag: any NSDraggingInfo) {
      catcher?.hovering(nil)
    }
  }
}
