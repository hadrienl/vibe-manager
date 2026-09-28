import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import VibeUI

/// A drag of the Finder, reduced to what a drop destination reads of it: a real pasteboard. Shared
/// with `DrawerDropTests`.
final class PasteboardDrag: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  let draggingLocation: NSPoint
  weak var draggingDestinationWindow: NSWindow?
  /// What the source lets be done: `.copy` for the Finder here, `.copy | .generic` for a text view.
  let draggingSourceOperationMask: NSDragOperation

  @MainActor
  init(
    pasteboard: NSPasteboard, location: NSPoint, window: NSWindow,
    sourceMask: NSDragOperation = .copy
  ) {
    draggingPasteboard = pasteboard
    draggingLocation = location
    draggingDestinationWindow = window
    draggingSourceOperationMask = sourceMask
  }

  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}

private struct RecordingDropDelegate: DropDelegate {
  let record: ([NSItemProvider]) -> Void

  func performDrop(info: DropInfo) -> Bool {
    record(info.itemProviders(for: DropReader.acceptedTypes))
    return true
  }
}

@MainActor
@Suite("Dropping files of the disk keeps their path (#131)")
struct FinderDropTests {
  private let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("FinderDropTests-\(UUID().uuidString)", isDirectory: true)

  private func png() throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func fixtures() throws -> [URL] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let text = folder.appendingPathComponent("simple.txt")
    try Data("a\n".utf8).write(to: text)
    let directory = folder.appendingPathComponent("un dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let image = folder.appendingPathComponent("chat.png")
    try png().write(to: image)
    return [text, directory, image]
  }

  /// Drags what `objects` write onto a SwiftUI drop zone, and reads what it was handed.
  private func drop(_ objects: [any NSPasteboardWriting]) async throws
    -> (items: [DroppedItem], failed: Int)
  {
    var received: [NSItemProvider] = []
    let host = NSHostingView(
      rootView: Color.clear.frame(width: 200, height: 200)
        .onDrop(
          of: DropReader.acceptedTypes,
          delegate: RecordingDropDelegate { received = $0 }))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    // The providers load from it after the drop: released once they are read.
    let pasteboard = NSPasteboard(name: .init("FinderDropTests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(objects)
    let destination = try #require(Self.dropDestination(in: host))
    let drag = PasteboardDrag(
      pasteboard: pasteboard, location: NSPoint(x: 100, y: 100), window: window)
    _ = destination.draggingEntered(drag)
    _ = destination.draggingUpdated(drag)
    _ = destination.prepareForDragOperation(drag)
    #expect(destination.performDragOperation(drag))
    #expect(received.count == objects.count)
    return await DropReader.read(received)
  }

  private static func dropDestination(in view: NSView) -> NSView? {
    if !view.registeredDraggedTypes.isEmpty { return view }
    return view.subviews.lazy.compactMap(dropDestination(in:)).first
  }

  private static func path(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  @Test("A text file, a folder and an image dropped from the Finder are their own paths")
  func finderDrop() async throws {
    let files = try fixtures()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (items, failed) = try await drop(files.map { $0 as NSURL })
    #expect(failed == 0)
    let paths = items.map { item -> String? in
      guard case .file(let url, _) = item else { return nil }
      return Self.path(url)
    }
    #expect(paths == files.map(Self.path))
  }

  @Test("An image with no file, a web address and a text are still bytes and text")
  func noFile() async throws {
    let data = try png()
    let image = NSPasteboardItem()
    image.setData(data, forType: .png)
    let address = try #require(NSURL(string: "https://example.com/a"))
    let (items, failed) = try await drop([image, address, "hello" as NSString])
    #expect(failed == 0)
    #expect(items.count == 3)
    if case .data(let bytes, _) = items.first {
      #expect(bytes == data)
    } else {
      Issue.record("not an image: \(String(describing: items.first))")
    }
    #expect(items.dropFirst() == [.text("https://example.com/a"), .text("hello")])
  }
}
