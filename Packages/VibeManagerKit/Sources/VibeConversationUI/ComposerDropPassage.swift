import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the drags of files through the composer's text field, to the view behind it (#146).
///
/// A file dropped on the conversation becomes a chip of the composer: the session's column takes
/// the drop, over all of its surface (ADR 0028). But the text view SwiftUI draws the field with
/// is an `NSTextView` registered for files too, and AppKit gives a drag to the frontmost visible
/// view under the pointer whose registered types meet the drag's: the field took a file first and
/// typed its path.
///
/// A transparent view laid over the field, `ComposerFileDropCatcher`, is registered for the types
/// of files, images and promised files only. In front of the field, it wins the drags that carry
/// one of them and leaves every other drag — a text, a web address, a selection of a page — to the
/// field, which inserts it where it is let go. It takes no click: AppKit finds a drag's destination
/// without asking `hitTest(_:)`. What it catches it relays, from the drag's entry to its end, to the
/// view that would have taken it without the field — the session's zone, which reads it as every
/// other drop.
@MainActor
enum ComposerDropPassage {
  /// What the catcher is registered for: files of the disk, images, promised files.
  static let fileTypes: [NSPasteboard.PasteboardType] =
    [
      .fileURL, .init("NSFilenamesPboardType"),
      .tiff, .init("NeXT TIFF v4.0 pasteboard type"), .png, .init("Apple PNG pasteboard type"),
      .init(UTType.jpeg.identifier), .init(UTType.heic.identifier), .init(UTType.gif.identifier),
      .init(UTType.webP.identifier), .init(UTType.image.identifier),
    ] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

  /// Whether a drag carries what the session's zone makes a chip of: a file of the disk — a
  /// folder, an image — an image with no file, or a file its source promises. A text, a web
  /// address or a selection of a page is left to the field.
  static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
    let promises = Set(NSFilePromiseReceiver.readableDraggedTypes)
    return (pasteboard.types ?? []).contains { type in
      if type == .fileURL || type == NSPasteboard.PasteboardType("NSFilenamesPboardType")
        || promises.contains(type.rawValue)
      {
        return true
      }
      guard let uti = UTType(type.rawValue) else { return false }
      return uti.conforms(to: .image) || uti.conforms(to: .fileURL)
    }
  }

  /// The view that takes a drag of `types` let go at `location`, in the window's coordinates,
  /// when neither the catcher nor a text field is there: the frontmost visible view under that
  /// point registered for one of those types.
  static func destination(
    behind catcher: NSView, at location: NSPoint, for types: [NSPasteboard.PasteboardType]
  ) -> NSView? {
    guard let root = catcher.window?.contentView else { return nil }
    return frontmost(in: root, at: location, for: types, excluding: catcher)
  }

  private static func frontmost(
    in view: NSView, at location: NSPoint, for types: [NSPasteboard.PasteboardType],
    excluding catcher: NSView
  ) -> NSView? {
    // Neither the catcher nor a text field — this one, or the composer of another conversation
    // of the stack.
    guard view !== catcher, !view.isHidden, !(view is NSTextView),
      view.bounds.contains(view.convert(location, from: nil))
    else { return nil }
    for subview in view.subviews.reversed() {
      if let found = frontmost(in: subview, at: location, for: types, excluding: catcher) {
        return found
      }
    }
    return accepts(view.registeredDraggedTypes, types) ? view : nil
  }

  /// Whether a view registered for `registered` takes a drag of `types`: one of them is
  /// registered, or conforms to a type that is — SwiftUI's zone registers `public.item`.
  static func accepts(
    _ registered: [NSPasteboard.PasteboardType], _ types: [NSPasteboard.PasteboardType]
  ) -> Bool {
    guard !registered.isEmpty else { return false }
    let exact = Set(registered)
    let general = registered.compactMap { UTType($0.rawValue) }
    return types.contains { type in
      if exact.contains(type) { return true }
      guard let uti = UTType(type.rawValue) else { return false }
      return general.contains { uti.conforms(to: $0) }
    }
  }
}

/// Laid over the composer's `TextEditor`: catches the drags of files and hands them to the
/// session's zone behind (#146).
struct ComposerFileDropCatcher: NSViewRepresentable {
  func makeNSView(context: Context) -> CatcherView { CatcherView() }

  func updateNSView(_ view: CatcherView, context: Context) {}

  final class CatcherView: NSView {
    /// The view the drag in progress is relayed to.
    private weak var target: NSView?

    override init(frame: NSRect) {
      super.init(frame: frame)
      registerForDraggedTypes(ComposerDropPassage.fileTypes)
      // Nothing to VoiceOver: the field under it is what is read and typed into.
      setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks, scrolling and the I-beam stay the field's.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func relay(_ drag: any NSDraggingInfo) -> NSView? {
      if let target { return target }
      let pasteboard = drag.draggingPasteboard
      guard ComposerDropPassage.carriesFiles(pasteboard) else { return nil }
      target = ComposerDropPassage.destination(
        behind: self, at: drag.draggingLocation, for: pasteboard.types ?? [])
      return target
    }

    override func draggingEntered(_ drag: any NSDraggingInfo) -> NSDragOperation {
      target = nil
      return relay(drag)?.draggingEntered(drag) ?? []
    }

    override func draggingUpdated(_ drag: any NSDraggingInfo) -> NSDragOperation {
      relay(drag)?.draggingUpdated(drag) ?? []
    }

    override func draggingExited(_ drag: (any NSDraggingInfo)?) {
      target?.draggingExited(drag)
      target = nil
    }

    override func prepareForDragOperation(_ drag: any NSDraggingInfo) -> Bool {
      target?.prepareForDragOperation(drag) ?? false
    }

    override func performDragOperation(_ drag: any NSDraggingInfo) -> Bool {
      target?.performDragOperation(drag) ?? false
    }

    override func concludeDragOperation(_ drag: (any NSDraggingInfo)?) {
      target?.concludeDragOperation(drag)
    }

    override func draggingEnded(_ drag: any NSDraggingInfo) {
      target?.draggingEnded(drag)
      target = nil
    }
  }
}
