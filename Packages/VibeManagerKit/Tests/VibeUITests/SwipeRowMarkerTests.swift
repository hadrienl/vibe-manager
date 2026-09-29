import AppKit
import Foundation
import SwiftUI
import Testing
import VibeDomain

@testable import VibeUI

@MainActor @Observable private final class Slide {
  var offset: CGFloat = 0
}

/// A selected row slides whole: its selection, drawn by the list behind the cell, goes with its
/// content, and comes back with it.
@MainActor
@Suite("A swiped row takes its selection along", .serialized, .timeLimit(.minutes(1)))
struct SwipeRowMarkerTests {
  private struct Sidebar: View {
    let ids: [SessionID]
    let slide: Slide
    @State var selection: SessionID?

    var body: some View {
      List(selection: $selection) {
        ForEach(ids, id: \.self) { id in
          Text(verbatim: "Session")
            .background(
              SwipeRowMarker(sessionID: id, carriesSelection: id == ids[1] && slide.offset != 0)
            )
            .offset(x: id == ids[1] ? slide.offset : 0)
            .tag(id)
        }
      }
      .listStyle(.sidebar)
    }
  }

  @Test func theSelectionSlidesWithTheRowAndComesBack() async throws {
    let ids = [SessionID(), SessionID(), SessionID()]
    let slide = Slide()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Sidebar(ids: ids, slide: slide, selection: ids[1]))
    window.orderFrontRegardless()
    defer {
      window.contentView = nil
      window.close()
    }

    await waitUntil("the list draws the row's selection") { selection(in: window) != nil }
    let selection = try #require(selection(in: window))
    let home = selection.convert(selection.bounds, to: nil)

    // As the fingers move: a few points first, then further, then the other way.
    for offset: CGFloat in [-4, -30, -120, 60] {
      slide.offset = offset
      await waitUntil("the card follows the row to \(offset)") {
        guard let card = card(in: window) else { return false }
        return card.convert(card.bounds, to: nil) == home.offsetBy(dx: offset, dy: 0)
          && selection.alphaValue == 0
      }
    }
    slide.offset = 0
    await waitUntil("the selection comes back") {
      card(in: window) == nil && selection.alphaValue == 1
    }
  }

  /// The rounded background the list draws behind a selected row.
  private func selection(in window: NSWindow) -> NSView? {
    selectedRow(in: window)?.subviews.first { $0 is NSVisualEffectView }
  }

  /// What stands in for the selection while the row slides, carried by the row's marker.
  private func card(in window: NSWindow) -> NSView? {
    window.contentView?.layoutSubtreeIfNeeded()
    return Self.all(SwipeRowMarker.MarkerView.self, in: window.contentView)
      .flatMap(\.subviews).first { $0 is NSVisualEffectView }
  }

  private func selectedRow(in window: NSWindow) -> NSTableRowView? {
    window.contentView?.layoutSubtreeIfNeeded()
    return Self.rows(in: window.contentView).first(where: \.isSelected)
  }

  private static func rows(in view: NSView?) -> [NSTableRowView] {
    all(NSTableRowView.self, in: view)
  }

  private static func all<V: NSView>(_ type: V.Type, in view: NSView?) -> [V] {
    guard let view else { return [] }
    if let match = view as? V { return [match] }
    return view.subviews.flatMap { all(type, in: $0) }
  }
}
