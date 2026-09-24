import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private func session(
  id: SessionID = SessionID(),
  name: String,
  // Active by default, so a test that says nothing about scope lands in the default one.
  status: SessionStatus = .active,
  providerID: String? = "claude-code",
  repositoryPaths: [String] = ["/work/api"],
  prompt: String = "",
  createdAt: Date = Date(timeIntervalSince1970: 100),
  updatedAt: Date = Date(timeIntervalSince1970: 100)
) -> WorkSession {
  WorkSession(
    id: id,
    name: name,
    initialPrompt: prompt,
    agent: providerID.map { SessionAgentConfiguration(providerID: $0) },
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    closedAt: status == .closed || status == .archived ? createdAt : nil,
    archivedAt: status == .archived ? updatedAt : nil,
    repositories: repositoryPaths.map { RepositoryContext(path: $0) }
  )
}

@Suite("Filtering the session history")
struct SessionFilterScopeTests {
  private let sessions = [
    session(name: "Running", status: .active),
    session(name: "Closed", status: .closed),
    session(name: "Archived", status: .archived),
  ]

  @Test("Active shows only the sessions with a live agent")
  func activeShowsOnlyRunningSessions() {
    let visible = SessionFilter(scope: .active).apply(to: sessions)
    #expect(visible.map(\.name) == ["Running"])
  }

  /// The split is running / finished, not archived / not. An archived session is a closed one
  /// that may not be reopened, so it is listed with the others rather than hidden away.
  @Test("Closed shows every finished session, archived ones included")
  func closedShowsArchivedToo() {
    let visible = SessionFilter(scope: .closed).apply(to: sessions)
    #expect(visible.map(\.name).sorted() == ["Archived", "Closed"])
  }

  @Test("A session is in exactly one scope")
  func scopesPartitionTheStore() {
    for session in sessions {
      let scopes = SessionScope.allCases.filter { $0.includes(session.status) }
      #expect(scopes.count == 1)
    }
  }
}

@Suite("Searching the session history")
struct SessionFilterSearchTests {
  @Test("Search ignores case and accents, and reaches the four fields that describe a session")
  func searchSpansNamePromptNotesAndPaths() {
    let byName = session(name: "Réfactoring PTY")
    let byPrompt = session(name: "Other", prompt: "Rewrite the RÉFACTORING plan")
    let byNotes = session(name: "Third")
    let notes = [byNotes.id: "refactoring was rolled back"]
    let byPath = session(name: "Fourth", repositoryPaths: ["/work/refactoring-tools"])
    let unrelated = session(name: "Docs", prompt: "Write the ADR")
    let all = [byName, byPrompt, byNotes, byPath, unrelated]

    let filter = SessionFilter(searchText: "refacto")

    #expect(filter.apply(to: all, notes: notes).count == 4)
    #expect(filter.matches(byNotes, notes: notes[byNotes.id]))
    #expect(!filter.matches(byNotes))
    #expect(!filter.matches(unrelated))
  }

  @Test("Whitespace alone is not a search")
  func blankSearchMatchesEverything() {
    let filter = SessionFilter(searchText: "   ")
    #expect(!filter.isNarrowing)
    #expect(filter.apply(to: [session(name: "Anything")]).count == 1)
  }

  @Test("Search and scope narrow together")
  func searchAppliesWithinTheScope() {
    let sessions = [
      session(name: "Refactor", status: .active),
      session(name: "Refactor", status: .closed),
    ]

    let filter = SessionFilter(scope: .closed, searchText: "refactor")

    #expect(filter.apply(to: sessions).map(\.status) == [.closed])
  }
}

@Suite("Facets and ordering")
struct SessionFilterFacetTests {
  @Test("The agent facet keeps only the sessions of the chosen providers")
  func agentFacetNarrows() {
    let sessions = [
      session(name: "One", providerID: "claude-code"),
      session(name: "Two", providerID: "codex"),
      session(name: "Three", providerID: nil),
    ]

    let filter = SessionFilter(agentProviderIDs: ["codex"])

    #expect(filter.apply(to: sessions).map(\.name) == ["Two"])
  }

  @Test("The folder facet keeps only the sessions that use it")
  func repositoryFacetNarrows() {
    let sessions = [
      session(name: "Api", repositoryPaths: ["/work/api"]),
      session(name: "Web", repositoryPaths: ["/work/web", "/work/api"]),
      session(name: "Docs", repositoryPaths: ["/work/docs"]),
    ]

    let filter = SessionFilter(repositoryPath: "/work/api")

    #expect(filter.apply(to: sessions).map(\.name).sorted() == ["Api", "Web"])
  }

  @Test("A facet that no longer names anything is dropped rather than emptying the list")
  func obsoleteFacetIsReconciled() {
    let sessions = [session(name: "One", providerID: "claude-code")]
    let filter = SessionFilter(
      agentProviderIDs: ["codex", "claude-code"],
      repositoryPath: "/gone"
    )

    let reconciled = filter.reconciled(with: sessions)

    #expect(reconciled.agentProviderIDs == ["claude-code"])
    #expect(reconciled.repositoryPath == nil)
    #expect(reconciled.apply(to: sessions).count == 1)
  }

  @Test("Only the agents and folders that exist are offered")
  func facetsComeFromTheSessions() {
    let sessions = [
      session(name: "One", providerID: "codex", repositoryPaths: ["/b"]),
      session(name: "Two", providerID: "claude-code", repositoryPaths: ["/a", "/b"]),
    ]

    #expect(SessionFilter.availableProviderIDs(in: sessions) == ["claude-code", "codex"])
    #expect(SessionFilter.availableRepositoryPaths(in: sessions) == ["/a", "/b"])
  }

  /// The order has to be the same at every launch, which means it cannot depend on the order the
  /// store happened to hand the sessions over in.
  @Test("Each ordering is total, so two runs over the same store draw the same list")
  func orderingIsTotal() {
    let sameInstant = Date(timeIntervalSince1970: 500)
    let first = session(
      id: SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
      name: "Same",
      createdAt: sameInstant,
      updatedAt: sameInstant
    )
    let second = session(
      id: SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
      name: "Same",
      createdAt: sameInstant,
      updatedAt: sameInstant
    )

    for sort in SessionSort.allCases {
      let filter = SessionFilter(sort: sort)
      #expect(filter.apply(to: [first, second]).map(\.id) == [first.id, second.id])
      #expect(filter.apply(to: [second, first]).map(\.id) == [first.id, second.id])
    }
  }

  @Test("Sorting by last activity, creation date and name")
  func sortsFollowTheirKey() {
    let older = session(
      name: "Zulu",
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 900)
    )
    let newer = session(
      name: "alpha",
      createdAt: Date(timeIntervalSince1970: 400),
      updatedAt: Date(timeIntervalSince1970: 500)
    )
    let sessions = [older, newer]

    #expect(
      SessionFilter(sort: .lastActivity).apply(to: sessions).map(\.name) == ["Zulu", "alpha"])
    #expect(SessionFilter(sort: .created).apply(to: sessions).map(\.name) == ["alpha", "Zulu"])
    // Localized, so lowercase does not sort after every capital letter.
    #expect(SessionFilter(sort: .name).apply(to: sessions).map(\.name) == ["alpha", "Zulu"])
  }
}

@Suite("What a filter remembers")
struct SessionFilterCodingTests {
  @Test("Scope, sort and facets are stored; the search text is not")
  func searchTextIsNeverPersisted() throws {
    let filter = SessionFilter(
      scope: .closed,
      sort: .name,
      searchText: "half-typed query",
      agentProviderIDs: ["codex"],
      repositoryPath: "/work/api"
    )

    let data = try JSONEncoder().encode(filter)
    let restored = try JSONDecoder().decode(SessionFilter.self, from: data)

    #expect(restored.scope == .closed)
    #expect(restored.sort == .name)
    #expect(restored.agentProviderIDs == ["codex"])
    #expect(restored.repositoryPath == "/work/api")
    #expect(restored.searchText.isEmpty)
    #expect(!String(decoding: data, as: UTF8.self).contains("half-typed"))
  }

  @Test("A document written before filters existed reads as the default view")
  func missingFilterFallsBack() throws {
    let data = Data("{}".utf8)
    let restored = try JSONDecoder().decode(SessionFilter.self, from: data)

    #expect(restored == SessionFilter())
    #expect(restored.scope == .active)
  }

  /// A filter is a preference, and a preference cannot be allowed to take the whole layout down
  /// with it: decoding a scope a later build introduced must cost the user their sort order at
  /// worst, not their columns, their widths and their selection.
  @Test("A value written by a later build falls back instead of throwing")
  func unknownRawValuesFallBack() throws {
    let data = Data(#"{"scope":"someFutureScope","sort":"byVibes"}"#.utf8)

    let restored = try JSONDecoder().decode(SessionFilter.self, from: data)

    #expect(restored.scope == .active)
    #expect(restored.sort == .lastActivity)
  }
}

@Suite("Searching by template")
struct SessionFilterTemplateTests {
  @Test("The name of the template a session came from is searched")
  func templateNameIsSearched() {
    var reviewed = session(name: "MR 1315")
    reviewed.template = PromptTemplateReference(id: "t", name: "Révision", revision: "1")
    let other = session(name: "Other")

    var filter = SessionFilter(scope: .active)
    filter.searchText = "revision"
    #expect(filter.apply(to: [reviewed, other]).map(\.name) == ["MR 1315"])
  }
}
