import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<400 where !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

/// A web view that answers what the test says, when the test says so.
@MainActor
private final class ScriptedReader: TicketPageReading {
  var outcomes: [String: TicketPageOutcome] = [:]
  /// Tickets whose page asks to sign in first; they answer once `signIn` is called.
  var signInFirst: Set<String> = []
  private(set) var read: [String] = []
  private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

  func readTicket(
    _ ticket: TicketRecognition, resolvers: TicketResolverSet, in session: SessionID,
    progress: @escaping @MainActor (TicketPageProgress) -> Void
  ) async -> TicketPageOutcome {
    read.append(ticket.shortID)
    progress(.loading)
    if signInFirst.contains(ticket.shortID) {
      progress(.signInRequired(host: "sso.example.com"))
      await withCheckedContinuation { waiting[ticket.shortID] = $0 }
      progress(.loading)
    }
    return outcomes[ticket.shortID] ?? .failed(.noTitle)
  }

  func signIn(_ shortID: String) {
    waiting.removeValue(forKey: shortID)?.resume()
  }

  func testTicketPage(_ ticket: TicketRecognition, resolvers: TicketResolverSet) async
    -> TicketPageOutcome
  {
    outcomes[ticket.shortID] ?? .failed(.noTitle)
  }

  func showTicket(_ ticket: TicketRecognition, resolvers: TicketResolverSet, in session: SessionID)
  {}
}

@MainActor
@Suite("Putting ticket titles at the top of the notes (#89)")
struct TicketTitlesTests {
  private let id = SessionID()
  private let resolvers = TicketResolverSet(TicketResolverPresets.all)

  private func tickets(_ numbers: [Int]) -> [TicketRecognition] {
    numbers.compactMap { resolvers.recognize("https://github.com/acme/app/issues/\($0)") }
  }

  private func make(
    notes: String = "", reader: ScriptedReader, enabled: Bool = true
  ) async -> (TicketTitlesModel, NotesModel) {
    let notesModel = NotesModel(store: InMemorySessionNotesStore(notes: [id: notes]))
    let model = TicketTitlesModel(
      repository: InMemoryTicketResolverRepository(),
      preferences: InMemoryTicketTitlePreferences(insertsTicketTitles: enabled),
      notes: notesModel, reader: reader)
    await model.load()
    let document = notesModel.document(for: id)
    await eventually { document.isLoaded }
    return (model, notesModel)
  }

  // MARK: The document

  @Test("A line goes first, above what was written, and ⌘Z takes it back")
  func insertAndUndo() async {
    let reader = ScriptedReader()
    let (_, notes) = await make(notes: "Mes notes", reader: reader)
    let document = notes.document(for: id)
    document.selection = NSRange(location: 3, length: 0)

    let result = document.insertTicketLine("[a#1] One — u1", address: "u1", rank: 0)

    #expect(result == .inserted)
    #expect(document.text == "[a#1] One — u1\n\nMes notes")
    #expect(document.selection.location == 3 + ("[a#1] One — u1\n\n" as NSString).length)
    #expect(document.hasUnsavedChanges)
    document.undoManager.undo()
    #expect(document.text == "Mes notes")
  }

  @Test("Lines keep the order the tickets were named, whatever order they come in")
  func order() async {
    let reader = ScriptedReader()
    let (_, notes) = await make(notes: "Texte", reader: reader)
    let document = notes.document(for: id)
    _ = document.insertTicketLine("three", address: "u3", rank: 2)
    _ = document.insertTicketLine("one", address: "u1", rank: 0)
    _ = document.insertTicketLine("two", address: "u2", rank: 1)
    #expect(document.text == "one\ntwo\nthree\n\nTexte")
  }

  @Test("Lines the user changed are left alone: the next line goes first")
  func changedBlock() async {
    let reader = ScriptedReader()
    let (_, notes) = await make(reader: reader)
    let document = notes.document(for: id)
    _ = document.insertTicketLine("one", address: "u1", rank: 0)
    document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Moi : ")
    document.didChange()
    _ = document.insertTicketLine("two", address: "u2", rank: 1)
    #expect(document.text == "two\n\nMoi : one\n")
  }

  @Test("An address already in the notes, or a line that would not fit, is not added")
  func refusals() async {
    let reader = ScriptedReader()
    let (_, notes) = await make(notes: "déjà https://x/1", reader: reader)
    let document = notes.document(for: id)
    #expect(document.insertTicketLine("one", address: "https://x/1", rank: 0) == .alreadyThere)
    let full = String(repeating: "x", count: SessionNotesLimits.byteLimit - 2)
    document.storage.setAttributedString(NSAttributedString(string: full))
    document.didChange()
    #expect(document.insertTicketLine("two", address: "u2", rank: 1) == .notesFull)
    #expect(document.text == full)
  }

  @Test("An address is only in the notes as a whole address")
  func wholeAddress() {
    let url = "https://github.com/acme/app/issues/12"
    #expect(!NotesDocument.contains(url, in: "voir \(url)3"))
    #expect(NotesDocument.contains(url, in: "voir \(url)#top"))
    #expect(NotesDocument.contains(url, in: "(\(url))"))
    #expect(NotesDocument.contains(url, in: url))
    #expect(!NotesDocument.contains(url, in: "\(url)-bis \(url)0"))
  }

  // MARK: The model

  @Test("Each title goes to the notes as it comes; a missing ticket is said")
  func titles() async {
    let reader = ScriptedReader()
    reader.outcomes = [
      "acme/app#1": .title("One", raw: "One · Issue #1 · acme/app"),
      "acme/app#2": .notFound(status: 404),
    ]
    let (model, notes) = await make(notes: "Notes", reader: reader)

    model.start(tickets([1, 2]), for: id)
    await eventually { model.entries[id]?.allSatisfy { !$0.state.isUnderWay } == true }

    #expect(reader.read == ["acme/app#1", "acme/app#2"])
    #expect(
      notes.document(for: id).text
        == "[acme/app#1] One — https://github.com/acme/app/issues/1\n\nNotes")
    #expect(model.entries[id]?.map(\.state) == [.inserted, .notFound(status: 404)])
  }

  @Test("A ticket waiting for a sign-in does not hold the next one, and keeps its place")
  func signIn() async {
    let reader = ScriptedReader()
    reader.signInFirst = ["acme/app#1"]
    reader.outcomes = [
      "acme/app#1": .title("One", raw: "One"), "acme/app#2": .title("Two", raw: "Two"),
    ]
    let (model, notes) = await make(reader: reader)
    let format = TicketLineFormat("{title}")
    model.lineFormat = format

    model.start(tickets([1, 2]), for: id)
    await eventually { model.entries[id]?.last?.state == .inserted }
    #expect(model.entries[id]?.first?.state == .signInRequired(host: "sso.example.com"))
    #expect(notes.document(for: id).text == "Two\n")

    reader.signIn("acme/app#1")
    await eventually { model.entries[id]?.first?.state == .inserted }
    #expect(notes.document(for: id).text == "One\nTwo\n")
  }

  @Test("Off, nothing is read at all")
  func off() async {
    let reader = ScriptedReader()
    let (model, _) = await make(reader: reader, enabled: false)
    #expect(await model.activeResolvers() == nil)
    model.start(tickets([1]), for: id)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(reader.read.isEmpty)
    #expect(model.entries[id] == nil)
  }

  @Test("Try Again reads only the tickets whose line is not in the notes")
  func retry() async {
    let reader = ScriptedReader()
    reader.outcomes = [
      "acme/app#1": .title("One", raw: "One"), "acme/app#2": .failed(.offline),
    ]
    let (model, _) = await make(reader: reader)
    model.start(tickets([1, 2]), for: id)
    await eventually { model.entries[id]?.allSatisfy { !$0.state.isUnderWay } == true }
    #expect(model.entries[id]?.last?.state == .failed(.offline))

    reader.outcomes["acme/app#2"] = .title("Two", raw: "Two")
    model.retry(id)
    await eventually { model.entries[id]?.last?.state == .inserted }
    #expect(reader.read == ["acme/app#1", "acme/app#2", "acme/app#2"])
  }

  @Test("The settings' test says what would be written, or that nothing would be loaded")
  func test() async {
    let reader = ScriptedReader()
    reader.outcomes = ["acme/app#3": .title("Three", raw: "Three · Issue #3 · acme/app")]
    let (model, _) = await make(reader: reader)
    let result = await model.test(
      "https://github.com/acme/app/issues/3", with: TicketResolverPresets.all)
    guard case .recognized(let ticket, let name, _, let line) = result else {
      Issue.record("not recognised")
      return
    }
    #expect(ticket.shortID == "acme/app#3")
    #expect(name == "GitHub")
    #expect(line == "[acme/app#3] Three — https://github.com/acme/app/issues/3")
    #expect(
      await model.test("https://example.com/3", with: TicketResolverPresets.all) == .notRecognized)
  }
}
