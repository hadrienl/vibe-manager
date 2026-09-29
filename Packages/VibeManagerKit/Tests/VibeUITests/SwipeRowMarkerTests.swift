import AppKit
import Foundation
import SwiftUI
import Testing
import VibeDomain

@testable import VibeUI

@MainActor @Observable private final class Board {
  var ids = [SessionID(), SessionID(), SessionID()]
  var selection: SessionID?
  /// The row that slides, and how far.
  var slid: SessionID?
  var offset: CGFloat = 0
}

/// A selected row slides whole: its selection, drawn by the list behind the cell, goes with its
/// content, and comes back with it.
@MainActor
@Suite("A swiped row takes its selection along", .serialized, .timeLimit(.minutes(1)))
struct SwipeRowMarkerTests {
  private struct Sidebar: View {
    @Bindable var board: Board

    var body: some View {
      List(selection: $board.selection) {
        ForEach(board.ids, id: \.self) { id in
          let offset = id == board.slid ? board.offset : 0
          Text(verbatim: "Session")
            .background(SwipeRowMarker(sessionID: id, carriesSelection: offset != 0))
            .offset(x: offset)
            .tag(id)
        }
      }
      .listStyle(.sidebar)
    }
  }

  @Test func theSelectionSlidesWithTheRowAndComesBack() async throws {
    let board = Board()
    board.selection = board.ids[1]
    board.slid = board.ids[1]
    let window = Self.window(showing: board)
    defer { Self.close(window) }

    await waitUntil("the list draws the row's selection") { selection(in: window) != nil }
    let selection = try #require(selection(in: window))
    let home = selection.convert(selection.bounds, to: nil)

    // As the fingers move: a few points first, then further, then the other way.
    for offset: CGFloat in [-4, -30, -120, 60] {
      board.offset = offset
      await waitUntil("the card follows the row to \(offset)") {
        guard let card = card(in: window) else { return false }
        return card.convert(card.bounds, to: nil) == home.offsetBy(dx: offset, dy: 0)
          && selection.alphaValue == 0
      }
    }
    board.offset = 0
    await waitUntil("the selection comes back") {
      card(in: window) == nil && selection.alphaValue == 1
    }
  }

  @Test func theSelectionComingToAnOpenRowOrLeavingItIsFollowed() async throws {
    let board = Board()
    board.selection = board.ids[0]
    board.slid = board.ids[1]
    let window = Self.window(showing: board)
    defer { Self.close(window) }
    // A row slides from where it rests.
    await waitUntil("the list draws its rows") { selectedRow(in: window) != nil }
    board.offset = -120

    await waitUntil("the list draws the first row's selection") { selection(in: window) != nil }
    #expect(card(in: window) == nil)

    board.selection = board.ids[1]
    await waitUntil("the open row takes the selection along") {
      guard let card = card(in: window), let selection = selection(in: window) else {
        return false
      }
      return selection.alphaValue == 0
        && card.convert(card.bounds, to: nil)
          == selection.convert(selection.bounds, to: nil).offsetBy(dx: -120, dy: 0)
    }

    board.selection = board.ids[2]
    await waitUntil("the card goes with the selection") {
      card(in: window) == nil && selection(in: window)?.alphaValue == 1
    }
  }

  @Test func theCardDimsWithTheListsSelection() async throws {
    let board = Board()
    board.selection = board.ids[1]
    board.slid = board.ids[1]
    let window = Self.window(showing: board)
    defer { Self.close(window) }
    // A row slides from where it rests.
    await waitUntil("the list draws its rows") { selectedRow(in: window) != nil }
    board.offset = -120

    await waitUntil("a card stands in for the selection") { card(in: window) != nil }
    let row = try #require(selectedRow(in: window))
    for emphasized in [!row.isEmphasized, row.isEmphasized] {
      row.isEmphasized = emphasized
      await waitUntil("the card is drawn \(emphasized ? "bright" : "dim")") {
        (card(in: window) as? NSVisualEffectView)?.isEmphasized
          == (selection(in: window) as? NSVisualEffectView)?.isEmphasized
      }
    }
  }

  @Test func aRowTakenAwayGivesItsSelectionBack() async throws {
    let board = Board()
    board.selection = board.ids[1]
    board.slid = board.ids[1]
    let window = Self.window(showing: board)
    defer { Self.close(window) }
    // A row slides from where it rests.
    await waitUntil("the list draws its rows") { selectedRow(in: window) != nil }
    board.offset = -120

    await waitUntil("a card stands in for the selection") { card(in: window) != nil }
    let selection = try #require(selection(in: window))

    board.ids.remove(at: 1)
    await waitUntil("the hidden selection is shown again") {
      card(in: window) == nil && selection.alphaValue == 1
    }
  }

  private static func window(showing board: Board) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: Sidebar(board: board))
    window.orderFrontRegardless()
    return window
  }

  private static func close(_ window: NSWindow) {
    window.contentView = nil
    window.close()
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
    return Self.all(NSTableRowView.self, in: window.contentView).first(where: \.isSelected)
  }

  private static func all<V: NSView>(_ type: V.Type, in view: NSView?) -> [V] {
    guard let view else { return [] }
    if let match = view as? V { return [match] }
    return view.subviews.flatMap { all(type, in: $0) }
  }
}
