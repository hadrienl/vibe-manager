import AppKit
import Foundation
import VibeApplication
import VibeDomain

/// The ticket lines at the top of a session's notes, in the order the tickets were named (#89).
struct TicketLineBlock: Equatable {
  struct Line: Equatable {
    /// The ticket's place among those the session named: lines keep that order whatever the
    /// order their pages answered in.
    let rank: Int
    let text: String
  }

  var lines: [Line]

  /// The block as the notes hold it: each line and its line break.
  var text: String {
    lines.map { $0.text + "\n" }.joined()
  }
}

/// What became of a ticket line handed to the notes.
public enum TicketLineInsertion: Hashable, Sendable {
  case inserted
  /// The notes already hold the ticket's address: typed or pasted meanwhile.
  case alreadyThere
  /// The line would take the notes over their limit.
  case notesFull
  /// The notes could not be read: nothing is ever written over them.
  case unreadable
}

extension NotesDocument {
  /// Puts a ticket's line at the top of the notes, as an edit of its own that ⌘Z takes back.
  ///
  /// Lines inserted earlier stay together at the top, in the order of `rank`, as long as nobody
  /// changed them; otherwise the line goes first. What was typed is never replaced, and the cursor
  /// stays on the word it was on.
  func insertTicketLine(_ line: String, address: String, rank: Int) -> TicketLineInsertion {
    guard isLoaded else { return .unreadable }
    let current = storage.string
    if Self.contains(address, in: current) { return .alreadyThere }

    var block = ticketLines.flatMap { current.hasPrefix($0.text) ? $0 : nil }
    let location: Int
    let insertion: String
    if var existing = block {
      let index = existing.lines.firstIndex { $0.rank > rank } ?? existing.lines.count
      location = (existing.lines[..<index].map { $0.text + "\n" }.joined() as NSString).length
      insertion = line + "\n"
      existing.lines.insert(.init(rank: rank, text: line), at: index)
      block = existing
    } else {
      location = 0
      insertion = current.isEmpty ? line + "\n" : line + "\n\n"
      block = TicketLineBlock(lines: [.init(rank: rank, text: line)])
    }
    guard byteCount + insertion.utf8.count <= SessionNotesLimits.byteLimit else {
      return .notesFull
    }

    breakTypingCoalescing?()
    let length = (insertion as NSString).length
    storage.replaceCharacters(
      in: NSRange(location: location, length: 0),
      with: NSAttributedString(string: insertion, attributes: NotesStyle.attributes))
    NotesLinks.apply(to: storage, around: NSRange(location: location, length: length))
    if selection.location >= location { selection.location += length }
    ticketLines = block

    let inserted = NSRange(location: location, length: length)
    undoManager.registerUndo(withTarget: self) { document in
      MainActor.assumeIsolated { document.removeTicketLine(insertion, at: inserted) }
    }
    undoManager.setActionName(
      String(
        localized: "Insert Ticket Title", bundle: .module,
        comment: "The undo action that takes back a ticket's line added to the notes."))
    didChange()
    return .inserted
  }

  /// Whether `text` holds `address` as a whole address: `…/issues/12` is not in `…/issues/123`,
  /// but is in `…/issues/12#top` or `(…/issues/12)`.
  static func contains(_ address: String, in text: String) -> Bool {
    let string = text as NSString
    var range = NSRange(location: 0, length: string.length)
    while true {
      let found = string.range(of: address, options: [], range: range)
      guard found.location != NSNotFound else { return false }
      let end = NSMaxRange(found)
      guard end < string.length else { return true }
      let next = string.substring(with: NSRange(location: end, length: 1))
      if next.rangeOfCharacter(from: .alphanumerics) == nil, !"-_.~%".contains(next) {
        return true
      }
      range = NSRange(location: end, length: string.length - end)
    }
  }

  /// ⌘Z: the line goes, if it is still where it was put.
  private func removeTicketLine(_ text: String, at range: NSRange) {
    let string = storage.string as NSString
    guard NSMaxRange(range) <= string.length, string.substring(with: range) == text else { return }
    storage.replaceCharacters(in: range, with: "")
    if selection.location >= NSMaxRange(range) { selection.location -= range.length }
    ticketLines = nil
    didChange()
  }
}

extension NotesModel {
  /// Hands a ticket's line to a session's notes, once they are read.
  func insertTicketLine(
    _ line: String, address: String, rank: Int, for id: SessionID
  ) async -> TicketLineInsertion {
    let document = document(for: id)
    for _ in 0..<200 where !document.isLoaded {
      if case .unreadable = document.state { return .unreadable }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return document.insertTicketLine(line, address: address, rank: rank)
  }
}
