import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private actor IdentityRepository: SessionRepository {
  private var values: [SessionID: WorkSession]
  private(set) var writes = 0

  init(_ sessions: [WorkSession]) {
    values = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
  }

  func sessions() -> [WorkSession] { Array(values.values) }
  func session(id: SessionID) -> WorkSession? { values[id] }
  func save(_ session: WorkSession) {
    writes += 1
    values[session.id] = session
  }

  func mutate(id: SessionID, _ transform: @Sendable (inout WorkSession) throws -> Void) async throws
    -> WorkSession?
  {
    guard var session = values[id] else { return nil }
    try transform(&session)
    save(session)
    return session
  }
}

private struct FolderIcons: ProjectIconFinding {
  let icons: [String: ProjectIcon]
  func icon(inFolder path: String) async -> ProjectIcon? { icons[path] }
}

private struct IconFailure: Error {}

@Suite("Renaming a session and changing its badge")
struct EditSessionIdentityTests {
  private let createdAt = Date(timeIntervalSince1970: 100)
  private let iconID = SessionIconID(sha256: String(repeating: "b", count: 64))!

  private var icon: ProjectIcon { ProjectIcon(id: iconID, pngData: Data([0x89, 0x50])) }

  /// A session with everything a rename must leave alone.
  private func session(_ status: SessionStatus = .active) -> WorkSession {
    WorkSession(
      name: "Fix the login",
      agent: SessionAgentConfiguration(
        providerID: "claude-code", modelID: "opus", resumeIdentifier: "conversation-1"),
      appearance: SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5"),
      status: status,
      createdAt: createdAt,
      updatedAt: createdAt.addingTimeInterval(50),
      closedAt: status == .active ? nil : createdAt.addingTimeInterval(20),
      archivedAt: status == .archived ? createdAt.addingTimeInterval(50) : nil,
      startedAt: createdAt,
      repositories: [
        RepositoryContext(
          path: "/work/app",
          git: GitSnapshot(
            repositoryRootPath: "/work/app", worktreePath: "/work/app-12", branchName: "fix/login",
            capturedAt: createdAt))
      ],
      ticket: SessionTicket(url: URL(string: "https://example.com/12")!, source: .manual),
      rank: 7
    )
  }

  /// The session as it was, with only its name and its badge taken from `edited`.
  private func expectOnlyIdentityChanged(_ edited: WorkSession, from original: WorkSession) {
    var expected = original
    expected.name = edited.name
    expected.appearance = edited.appearance
    #expect(edited == expected)
  }

  @Test(
    "A rename writes the name and nothing else, whatever the session's state",
    arguments: [SessionStatus.active, .closed, .archived])
  func renameWritesOnlyTheName(status: SessionStatus) async throws {
    let original = session(status)
    let repository = IdentityRepository([original])
    let edit = EditSessionIdentity(repository: repository)

    let change = try await edit.rename(original.id, to: "  Fix the sign-in\n")

    let stored = try #require(await repository.session(id: original.id))
    #expect(stored.name == "Fix the sign-in")
    expectOnlyIdentityChanged(stored, from: original)
    #expect(stored.updatedAt == original.updatedAt)
    #expect(stored.rank == 7)
    #expect(stored.agent?.resumeIdentifier == "conversation-1")
    #expect(stored.repositories.first?.git?.branchName == "fix/login")
    #expect(change?.before.name == "Fix the login")
    #expect(change?.after.name == "Fix the sign-in")
  }

  @Test("A refused name leaves the store as it was, and says why")
  func refusedName() async throws {
    let original = session()
    let repository = IdentityRepository([original])
    let edit = EditSessionIdentity(repository: repository)

    await #expect(throws: SessionDraftIssue.nameMissing) {
      try await edit.rename(original.id, to: "   ")
    }
    await #expect(throws: SessionDraftIssue.nameTooLong) {
      try await edit.rename(original.id, to: String(repeating: "a", count: 121))
    }
    #expect(await repository.session(id: original.id) == original)
    #expect(await repository.writes == 0)
  }

  @Test("The same name again writes nothing, and leaves nothing to undo")
  func sameNameIsNoChange() async throws {
    let original = session()
    let repository = IdentityRepository([original])

    let change = try await EditSessionIdentity(repository: repository)
      .rename(original.id, to: "Fix the login ")

    #expect(change == nil)
    #expect(await repository.writes == 0)
  }

  @Test("A session no longer stored is reported")
  func missingSession() async {
    let edit = EditSessionIdentity(repository: IdentityRepository([]))
    await #expect(throws: SessionIdentityError.sessionNotFound) {
      try await edit.rename(SessionID(), to: "Anything")
    }
  }

  @Test("A new badge writes the badge and nothing else")
  func appearanceWritesOnlyTheBadge() async throws {
    let original = session(.closed)
    let repository = IdentityRepository([original])
    let appearance = SessionAppearance(symbolName: "flask", colorHex: "#1E7F4D")

    let change = try await EditSessionIdentity(repository: repository)
      .setAppearance(appearance, for: original.id)

    let stored = try #require(await repository.session(id: original.id))
    #expect(stored.appearance == appearance)
    expectOnlyIdentityChanged(stored, from: original)
    #expect(change?.before.appearance == original.appearance)
  }

  @Test("A badge that cannot be stored is refused")
  func invalidAppearance() async {
    let original = session()
    let edit = EditSessionIdentity(repository: IdentityRepository([original]))
    await #expect(throws: SessionIdentityError.invalidAppearance) {
      try await edit.setAppearance(
        SessionAppearance(symbolName: "bolt", colorHex: "blue"), for: original.id)
    }
  }

  @Test("The project's icon is copied before the session names it")
  func iconIsKeptFirst() async throws {
    let original = session()
    let repository = IdentityRepository([original])
    let icons = InMemorySessionIconStore()
    var appearance = original.appearance
    appearance.iconID = iconID

    try await EditSessionIdentity(repository: repository, icons: icons)
      .setAppearance(appearance, keeping: icon, for: original.id)

    #expect(await icons.pngData(for: iconID) == icon.pngData)
    #expect(await repository.session(id: original.id)?.appearance.iconID == iconID)
  }

  @Test("An icon that cannot be copied changes nothing")
  func iconFailureChangesNothing() async throws {
    let original = session()
    let repository = IdentityRepository([original])
    var appearance = original.appearance
    appearance.iconID = iconID
    let edit = EditSessionIdentity(
      repository: repository, icons: InMemorySessionIconStore(failure: IconFailure()))

    await #expect(throws: SessionIdentityError.iconNotKept) {
      try await edit.setAppearance(appearance, keeping: icon, for: original.id)
    }
    #expect(await repository.session(id: original.id) == original)
  }

  @Test("The default badge is the one a creation would give: the folder's icon over the name's")
  func defaultAppearanceWithIcon() async {
    let original = session()
    let edit = EditSessionIdentity(
      repository: IdentityRepository([original]),
      projectIcons: FolderIcons(icons: ["/work/app": icon]))

    let (appearance, found) = await edit.defaultAppearance(for: original)

    #expect(found == icon)
    #expect(
      appearance
        == SessionAppearanceCatalog.defaultAppearance(forName: "Fix the login", projectIcon: iconID))
  }

  @Test("Without an icon in its folder, or without a folder, the name alone decides")
  func defaultAppearanceWithoutIcon() async {
    var original = session()
    let edit = EditSessionIdentity(
      repository: IdentityRepository([original]), projectIcons: FolderIcons(icons: [:]))

    let (appearance, found) = await edit.defaultAppearance(for: original)
    #expect(found == nil)
    #expect(appearance == SessionAppearanceCatalog.derived(forName: "Fix the login"))

    original.repositories = []
    #expect(await edit.defaultAppearance(for: original).appearance == appearance)
  }

  @Test("Undoing puts the identity back, unless it was changed since")
  func applyChecksTheCurrentIdentity() async throws {
    let original = session()
    let repository = IdentityRepository([original])
    let edit = EditSessionIdentity(repository: repository)
    let change = try #require(try await edit.rename(original.id, to: "Renamed"))

    #expect(try await edit.apply(change.reversed) == change.reversed)
    #expect(await repository.session(id: original.id)?.name == "Fix the login")

    // Changed again since: redoing the first rename over it would lose that change.
    try await edit.rename(original.id, to: "Another name")
    #expect(try await edit.apply(change) == nil)
    #expect(await repository.session(id: original.id)?.name == "Another name")
  }
}

@Suite("The history of renames and badge changes")
struct SessionIdentityHistoryTests {
  private func change(_ id: SessionID, _ from: String, _ to: String) -> SessionIdentityChange {
    let appearance = SessionAppearance()
    return SessionIdentityChange(
      id: id, before: SessionIdentity(name: from, appearance: appearance),
      after: SessionIdentity(name: to, appearance: appearance))
  }

  @Test("Undo gives the reverse of the last change, and redo gives it back")
  func undoRedo() throws {
    let id = SessionID()
    var history = SessionIdentityHistory()
    history.record(change(id, "A", "B"))
    history.record(change(id, "B", "C"))

    let popped = history.popUndo()
    let undo = try #require(popped)
    #expect(undo == change(id, "C", "B"))
    history.didUndo(undo)
    #expect(history.canRedo)

    let poppedRedo = history.popRedo()
    let redo = try #require(poppedRedo)
    #expect(redo == change(id, "B", "C"))
    history.didRedo(redo)
    #expect(!history.canRedo)
    #expect(history.undoStack.count == 2)
  }

  @Test("A new change clears what could be redone")
  func newChangeClearsRedo() throws {
    let id = SessionID()
    var history = SessionIdentityHistory()
    history.record(change(id, "A", "B"))
    let popped = history.popUndo()
    history.didUndo(try #require(popped))
    history.record(change(id, "A", "D"))
    #expect(!history.canRedo)
  }

  @Test("An undo dropped because the session changed since is gone for good")
  func droppedUndo() {
    var history = SessionIdentityHistory()
    history.record(change(SessionID(), "A", "B"))
    _ = history.popUndo()
    #expect(!history.canUndo)
    #expect(!history.canRedo)
  }

  @Test("Only the last 50 changes are kept")
  func limit() {
    let id = SessionID()
    var history = SessionIdentityHistory()
    for index in 0..<60 { history.record(change(id, "\(index)", "\(index + 1)")) }
    #expect(history.undoStack.count == SessionIdentityHistory.limit)
    #expect(history.undoStack.first == change(id, "10", "11"))
  }

  @Test("The changes of a session no longer stored are forgotten")
  func forgetsRemovedSessions() {
    let kept = SessionID()
    var history = SessionIdentityHistory()
    history.record(change(kept, "A", "B"))
    history.record(change(SessionID(), "C", "D"))
    history.keep(only: [kept])
    #expect(history.undoStack == [change(kept, "A", "B")])
  }
}
