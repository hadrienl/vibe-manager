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
            .background(SwipeRowMarker(sessionID: id, offset: id == ids[1] ? slide.offset : 0))
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
    let home = selection.frame

    slide.offset = -120
    await waitUntil("a card slides left in place of the selection") {
      card(in: window)?.frame == home.offsetBy(dx: -120, dy: 0) && selection.alphaValue == 0
    }
    slide.offset = 60
    await waitUntil("the card slides right") {
      card(in: window)?.frame == home.offsetBy(dx: 60, dy: 0)
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

  /// What stands in for the selection, drawn just above it, while the row slides.
  private func card(in window: NSWindow) -> NSView? {
    let effects = selectedRow(in: window)?.subviews.filter { $0 is NSVisualEffectView } ?? []
    return effects.count > 1 ? effects[1] : nil
  }

  private func selectedRow(in window: NSWindow) -> NSTableRowView? {
    window.contentView?.layoutSubtreeIfNeeded()
    return Self.rows(in: window.contentView).first(where: \.isSelected)
  }

  private static func rows(in view: NSView?) -> [NSTableRowView] {
    guard let view else { return [] }
    if let row = view as? NSTableRowView { return [row] }
    return view.subviews.flatMap { rows(in: $0) }
  }
}
