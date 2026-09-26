import Foundation
import VibeDomain

/// Every session as Open Quickly searches it (#37): its title, its folders, the resources and the
/// summary of its journal (#36), the URLs of its first prompt and its notes, archived sessions
/// included.
///
/// Held in memory and prepared once — folded, canonical — when a session, a journal or the notes
/// change: a keystroke only walks arrays, it never reads the disk. Rebuilt at every launch, in the
/// background; the palette searches what is already there while the journals are being read.
public actor SessionSearchIndex {
  /// How many results a search gives at most.
  public static let resultLimit = 50
  /// How many sessions the empty palette offers.
  public static let recentLimit = 8
  /// A word shorter than this does not search the summary or the notes: it would match anything.
  static let longTextMinimum = 2

  private var sessions: [SessionID: WorkSession] = [:]
  private var journals: [SessionID: JournalPart] = [:]
  /// Sessions whose journal came from the monitor: a journal read from the disk afterwards is
  /// older, and does not replace it.
  private var liveJournals: Set<SessionID> = []
  private var notes: [SessionID: FoldedText] = [:]
  private var rows: [SessionID: IndexedSession] = [:]
  /// Resolving a folder asks the disk: done once per spelling.
  private var canonicalPaths: [String: String] = [:]

  public init() {}

  // MARK: - Keeping it current

  /// The sessions as the store has them. Only those that changed are prepared again.
  public func update(sessions list: [WorkSession]) {
    let ids = Set(list.map(\.id))
    for id in sessions.keys where !ids.contains(id) {
      sessions[id] = nil
      journals[id] = nil
      liveJournals.remove(id)
      notes[id] = nil
      rows[id] = nil
    }
    for session in list where sessions[session.id] != session {
      sessions[session.id] = session
      rebuild(session.id)
    }
  }

  /// A journal the monitor published, or one read from the disk (`live: false`).
  public func update(journal: SessionJournal, for id: SessionID, live: Bool = true) {
    if live {
      liveJournals.insert(id)
    } else if liveJournals.contains(id) {
      return
    }
    journals[id] = JournalPart(journal)
    rebuild(id)
  }

  /// Every session's notes, by session. Only those whose text changed are prepared again.
  public func update(notes all: [SessionID: String]) {
    for id in notes.keys where all[id] == nil {
      notes[id] = nil
      rebuild(id)
    }
    for (id, text) in all where notes[id]?.text != text {
      notes[id] = FoldedText(text)
      rebuild(id)
    }
  }

  /// Reads the journal of each session, one after the other, and says how far it has got.
  public func loadJournals(
    for ids: [SessionID],
    read: @Sendable (SessionID) async -> SessionJournal?,
    progress: @Sendable (_ done: Int, _ total: Int) async -> Void
  ) async {
    await progress(0, ids.count)
    for (index, id) in ids.enumerated() {
      if Task.isCancelled { return }
      if !liveJournals.contains(id), let journal = await read(id) {
        update(journal: journal, for: id, live: false)
      }
      await progress(index + 1, ids.count)
    }
  }

  var indexedCount: Int { rows.count }

  private func rebuild(_ id: SessionID) {
    guard let session = sessions[id] else {
      rows[id] = nil
      return
    }
    rows[id] = IndexedSession(
      session: session, journal: journals[id], notes: notes[id],
      canonical: { canonicalPath($0) })
  }

  private func canonicalPath(_ path: String) -> String {
    if let known = canonicalPaths[path] { return known }
    let canonical = CanonicalPath.of(path)
    canonicalPaths[path] = canonical
    return canonical
  }

  // MARK: - Searching

  /// The sessions that answer `text`, best first. With nothing typed, the sessions last worked
  /// in, the one on screen left out.
  public func search(
    _ text: String, limit: Int = SessionSearchIndex.resultLimit, excluding: SessionID? = nil
  ) -> QuickOpenAnswer {
    let query = QuickOpenQuery(text)
    guard !query.isEmpty else {
      let recent =
        rows.values
        .filter { !$0.isArchived && $0.id != excluding }
        .sorted(by: IndexedSession.byActivity)
        .prefix(Self.recentLimit)
        .map {
          QuickOpenResult(
            sessionID: $0.id, rank: .recent, reason: .recent, isArchived: false, highlights: [])
        }
      return QuickOpenAnswer(query: query, results: Array(recent))
    }

    let matcher = Matcher(query: query)
    var found: [(match: Match, row: IndexedSession)] = []
    for row in rows.values {
      if let match = matcher.bestMatch(in: row) { found.append((match, row)) }
    }
    found.sort { lhs, rhs in
      if lhs.match.rank != rhs.match.rank { return lhs.match.rank < rhs.match.rank }
      if lhs.row.isArchived != rhs.row.isArchived { return !lhs.row.isArchived }
      let left = lhs.match.involvement?.rawValue ?? -1
      let right = rhs.match.involvement?.rawValue ?? -1
      if left != right { return left > right }
      return IndexedSession.byActivity(lhs.row, rhs.row)
    }
    let results = found.prefix(limit).map { match, row in
      QuickOpenResult(
        sessionID: row.id, rank: match.rank, reason: match.reason(in: row),
        isArchived: row.isArchived, highlights: matcher.highlights)
    }
    return QuickOpenAnswer(
      query: query, results: results,
      unmatchedResource: results.isEmpty ? Self.namedResource(query) : nil)
  }

  /// The ticket or request a query names without ambiguity, to say it was understood.
  private static func namedResource(_ query: QuickOpenQuery) -> QuickOpenReason? {
    guard case .resourceKey = query.criteria.first, let url = URL(string: query.text),
      let resource = ResourceRecognizer.resource(for: url, involvement: .viewed, at: .distantPast)
    else { return nil }
    return .resource(
      kind: resource.kind, label: resource.label, context: resource.context, involvement: nil)
  }
}

// MARK: - What is kept of a session

/// The part of a journal the search reads: no cursors, no pending turns.
struct JournalPart: Sendable {
  let resources: [SessionResource]
  let entries: [FoldedText]
  let lastActivity: Date?

  init(_ journal: SessionJournal) {
    resources = journal.resources
    entries = journal.entries.filter { !$0.text.isEmpty }.map { FoldedText($0.text) }
    lastActivity =
      [journal.entries.last?.at, journal.resources.map(\.lastSeenAt).max()]
      .compactMap { $0 }.max()
  }
}

/// Text kept as it was, for showing, and folded into bytes, for finding.
struct FoldedText: Sendable {
  let text: String
  let bytes: [UInt8]

  init(_ text: String) {
    self.text = text
    bytes = Array(Folding.fold(text).utf8)
  }

  func contains(_ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty else { return true }
    guard needle.count <= bytes.count else { return false }
    return bytes.withUnsafeBytes { haystack in
      needle.withUnsafeBytes { needle in
        memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
      }
    }
  }

  func containsAll(_ needles: [[UInt8]]) -> Bool {
    needles.allSatisfy(contains)
  }
}

struct IndexedResource: Sendable {
  let kind: SessionResource.Kind
  let key: String?
  let label: String
  let context: String?
  let involvement: SessionResource.Involvement?
  /// A ticket's or a request's number.
  let number: Int?
  let isGitLab: Bool
  let isMergeRequest: Bool
  /// The repository, lowercased, cut at its slashes: `vibe-manager#36` is compared by its end.
  let contextComponents: [String]
  /// The label, or the name of the branch.
  let name: FoldedText
  /// The label and the repository together, for words typed across both.
  let searchable: FoldedText
  /// A worktree's folder, canonical.
  let path: String?

  init(_ resource: SessionResource, canonical: (String) -> String) {
    kind = resource.kind
    key = resource.key
    label = resource.label
    context = resource.context
    involvement = resource.involvement
    isGitLab = resource.key.hasPrefix("gitlab:")
    isMergeRequest = isGitLab && resource.key.contains("#mr/")
    number = resource.key.split(separator: "/").last.flatMap {
      Int($0.split(separator: "#").last ?? "")
    }
    .flatMap { resource.kind == .issue || resource.kind == .pullRequest ? $0 : nil }
    contextComponents = (resource.context ?? "").lowercased().split(separator: "/").map(String.init)
    name = FoldedText(resource.label)
    searchable = FoldedText(
      [resource.label, resource.context].compactMap { $0 }.joined(separator: " "))
    if case .folder(let folder) = resource.target {
      path = canonical(folder)
    } else {
      path = nil
    }
  }

  /// A branch or a worktree the session recorded itself, for sessions older than the journal.
  init(branch: String, repository: String) {
    kind = .branch
    key = nil
    label = branch
    context = repository
    involvement = nil
    number = nil
    isGitLab = false
    isMergeRequest = false
    contextComponents = []
    name = FoldedText(branch)
    searchable = FoldedText("\(branch) \(repository)")
    path = nil
  }

  init(worktree: String, canonical: String) {
    kind = .worktree
    key = nil
    label = (worktree as NSString).lastPathComponent
    context = nil
    involvement = nil
    number = nil
    isGitLab = false
    isMergeRequest = false
    contextComponents = []
    name = FoldedText(label)
    searchable = FoldedText(canonical)
    path = canonical
  }
}

struct IndexedFolder: Sendable {
  /// As the session has it.
  let path: String
  let canonical: String
  let folded: FoldedText
}

struct IndexedSession: Sendable {
  let id: SessionID
  let title: FoldedText
  let isArchived: Bool
  let lastActivity: Date
  let resources: [IndexedResource]
  let folders: [IndexedFolder]
  let entries: [FoldedText]
  let notes: FoldedText?

  init(
    session: WorkSession, journal: JournalPart?, notes: FoldedText?,
    canonical: (String) -> String
  ) {
    id = session.id
    title = FoldedText(session.name)
    isArchived = session.taskStatus == .archived
    lastActivity = max(session.updatedAt, journal?.lastActivity ?? .distantPast)
    entries = journal?.entries ?? []
    self.notes = notes

    var resources = (journal?.resources ?? []).map { IndexedResource($0, canonical: canonical) }
    var keys = Set(resources.compactMap(\.key))
    // The URLs of the first prompt: a session older than the journal is still found by the ticket
    // it was started on.
    for resource in ResourceRecognizer.urls(
      in: session.initialPrompt, involvement: .viewed, at: session.createdAt)
    where keys.insert(resource.key).inserted {
      resources.append(IndexedResource(resource, canonical: canonical))
    }
    var folders: [IndexedFolder] = []
    for repository in session.repositories {
      let canonicalPath = canonical(repository.path)
      folders.append(
        IndexedFolder(
          path: repository.path, canonical: canonicalPath, folded: FoldedText(repository.path)))
      guard let git = repository.git else { continue }
      let name = (git.repositoryRootPath as NSString).lastPathComponent
      if let branch = git.branchName,
        !resources.contains(where: { $0.kind == .branch && $0.label == branch })
      {
        resources.append(IndexedResource(branch: branch, repository: name))
      }
      if let worktree = git.worktreePath, worktree != git.repositoryRootPath {
        let path = canonical(worktree)
        if !resources.contains(where: { $0.kind == .worktree && $0.path == path }) {
          resources.append(IndexedResource(worktree: worktree, canonical: path))
        }
      }
    }
    self.resources = resources
    self.folders = folders
  }

  /// Last worked in first, then by title, then by identifier: a total order, stable from one
  /// keystroke to the next.
  static func byActivity(_ lhs: IndexedSession, _ rhs: IndexedSession) -> Bool {
    if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
    let comparison = lhs.title.text.localizedStandardCompare(rhs.title.text)
    if comparison != .orderedSame { return comparison == .orderedAscending }
    return lhs.id.description < rhs.id.description
  }
}

// MARK: - Matching

/// What made a session answer.
enum MatchSource: Sendable {
  case resource(Int)
  case title
  case folder(Int)
  case entry(Int)
  case notes
}

struct Match: Sendable {
  let rank: QuickOpenRank
  let source: MatchSource
  let involvement: SessionResource.Involvement?
  /// The words to find in a long text, to cut it around them.
  let words: [String]

  func isBetter(than other: Match?) -> Bool {
    guard let other else { return true }
    if rank != other.rank { return rank < other.rank }
    return (involvement?.rawValue ?? -1) > (other.involvement?.rawValue ?? -1)
  }

  func reason(in row: IndexedSession) -> QuickOpenReason {
    switch source {
    case .resource(let index):
      let resource = row.resources[index]
      return .resource(
        kind: resource.kind, label: resource.label, context: resource.context,
        involvement: resource.involvement)
    case .title:
      return .title
    case .folder(let index):
      return .folder(row.folders[index].path)
    case .entry(let index):
      return .summary(Excerpt.around(words, in: row.entries[index].text))
    case .notes:
      return .notes(Excerpt.around(words, in: row.notes?.text ?? ""))
    }
  }
}

struct Matcher {
  let query: QuickOpenQuery
  /// Every word typed, as typed, for the palette to set in bold.
  let highlights: [String]

  init(query: QuickOpenQuery) {
    self.query = query
    var highlights: [String] = []
    for criterion in query.criteria {
      if case .text = criterion {
        highlights = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
      }
    }
    self.highlights = highlights
  }

  func bestMatch(in row: IndexedSession) -> Match? {
    var best: Match?
    for criterion in query.criteria {
      let match: Match?
      switch criterion {
      case .resourceKey(let key):
        match = resourceMatch(in: row, rank: .exactResource) { $0.key == key }
      case .number(let number, let sign, let context):
        match = numberMatch(number, sign: sign, context: context, in: row)
      case .branch(let name):
        let folded = Array(Folding.fold(name).utf8)
        match = resourceMatch(in: row, rank: .exactResource) {
          $0.kind == .branch && $0.name.bytes == folded
        }
      case .path(let path):
        match = pathMatch(path, in: row)
      case .text(let words):
        match = textMatch(words, in: row)
      }
      if let match, match.isBetter(than: best) { best = match }
    }
    return best
  }

  private func resourceMatch(
    in row: IndexedSession, rank: QuickOpenRank, where predicate: (IndexedResource) -> Bool
  ) -> Match? {
    var best: Match?
    for (index, resource) in row.resources.enumerated() where predicate(resource) {
      let match = Match(
        rank: rank, source: .resource(index), involvement: resource.involvement, words: [])
      if match.isBetter(than: best) { best = match }
    }
    return best
  }

  private func numberMatch(
    _ number: Int, sign: QuickOpenQuery.NumberSign, context: [String], in row: IndexedSession
  ) -> Match? {
    var best: Match?
    for (index, resource) in row.resources.enumerated() where resource.number == number {
      // GitLab numbers tickets and merge requests apart; GitHub numbers them together.
      if resource.isGitLab {
        if sign == .hash, resource.isMergeRequest { continue }
        if sign == .bang, !resource.isMergeRequest { continue }
      }
      let rank: QuickOpenRank
      if context.isEmpty {
        rank = .exactName
      } else if resource.contextComponents.count >= context.count,
        Array(resource.contextComponents.suffix(context.count)) == context
      {
        rank = .exactResource
      } else {
        continue
      }
      let match = Match(
        rank: rank, source: .resource(index), involvement: resource.involvement, words: [])
      if match.isBetter(than: best) { best = match }
    }
    return best
  }

  private func pathMatch(_ path: String, in row: IndexedSession) -> Match? {
    func relates(_ folder: String) -> Bool {
      folder.hasPrefix(path + "/") || path.hasPrefix(folder + "/")
    }
    var best: Match?
    for (index, resource) in row.resources.enumerated() {
      guard let folder = resource.path else { continue }
      let rank: QuickOpenRank
      if folder == path {
        rank = .exactName
      } else if relates(folder) {
        rank = .partialResource
      } else {
        continue
      }
      let match = Match(
        rank: rank, source: .resource(index), involvement: resource.involvement, words: [])
      if match.isBetter(than: best) { best = match }
    }
    for (index, folder) in row.folders.enumerated() {
      let rank: QuickOpenRank
      if folder.canonical == path {
        rank = .exactName
      } else if relates(folder.canonical) {
        rank = .folder
      } else {
        continue
      }
      let match = Match(rank: rank, source: .folder(index), involvement: nil, words: [])
      if match.isBetter(than: best) { best = match }
    }
    return best
  }

  /// Every word in one place first; failing that, each word somewhere, the session then as good
  /// as its weakest word, and said by its strongest.
  private func textMatch(_ words: [String], in row: IndexedSession) -> Match? {
    let needles = words.map { Array($0.utf8) }
    if let match = fieldMatch(needles, words: words, in: row) { return match }
    guard words.count > 1 else { return nil }
    var matches: [Match] = []
    for (word, needle) in zip(words, needles) {
      guard let match = fieldMatch([needle], words: [word], in: row) else { return nil }
      matches.append(match)
    }
    guard let weakest = matches.map(\.rank).max(),
      let strongest = matches.min(by: { $0.isBetter(than: $1) })
    else { return nil }
    return Match(
      rank: weakest, source: strongest.source, involvement: strongest.involvement,
      words: strongest.words)
  }

  private func fieldMatch(_ needles: [[UInt8]], words: [String], in row: IndexedSession) -> Match? {
    var best: Match?
    func consider(_ match: Match) {
      if match.isBetter(than: best) { best = match }
    }
    for (index, resource) in row.resources.enumerated() {
      let rank: QuickOpenRank
      if needles.count == 1, resource.kind == .branch || resource.kind == .worktree,
        resource.name.bytes == needles[0]
      {
        rank = .exactName
      } else if resource.searchable.containsAll(needles) {
        rank = .partialResource
      } else {
        continue
      }
      consider(
        Match(rank: rank, source: .resource(index), involvement: resource.involvement, words: []))
    }
    if best?.rank ?? .recent <= .partialResource { return best }
    if row.title.containsAll(needles) {
      return Match(rank: .title, source: .title, involvement: nil, words: [])
    }
    for (index, folder) in row.folders.enumerated() where folder.folded.containsAll(needles) {
      return Match(rank: .folder, source: .folder(index), involvement: nil, words: [])
    }
    guard needles.allSatisfy({ $0.count >= SessionSearchIndex.longTextMinimum }) else {
      return nil
    }
    // The latest line first: it is the one that says where the session stands.
    for index in row.entries.indices.reversed() where row.entries[index].containsAll(needles) {
      return Match(rank: .summary, source: .entry(index), involvement: nil, words: words)
    }
    if let notes = row.notes, notes.containsAll(needles) {
      return Match(rank: .notes, source: .notes, involvement: nil, words: words)
    }
    return nil
  }
}

/// A piece of a long text around what matched, on one line.
enum Excerpt {
  static let before = 30
  static let after = 60

  static func around(_ words: [String], in text: String) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    let options: String.CompareOptions = [
      .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]
    let found = words.lazy.compactMap { flat.range(of: $0, options: options) }.first
    guard let found else { return String(flat.prefix(before + after)) }
    let start =
      flat.index(found.lowerBound, offsetBy: -before, limitedBy: flat.startIndex)
      ?? flat.startIndex
    let end =
      flat.index(found.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex
    var excerpt = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
    if start > flat.startIndex { excerpt = "…" + excerpt }
    if end < flat.endIndex { excerpt += "…" }
    return excerpt
  }
}
