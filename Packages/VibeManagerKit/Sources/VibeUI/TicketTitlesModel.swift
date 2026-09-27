import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The titles of the tickets a session named when it was created, read in its web view and put at
/// the top of its notes (#89) — and the settings that say how.
///
/// A creation gesture only: nothing here runs again at a restart or a restoration, and nothing in
/// it is waited for before the agent starts.
@MainActor
@Observable
public final class TicketTitlesModel {
  /// Where one ticket of a session stands.
  public enum State: Hashable, Sendable {
    case waiting
    case reading
    case signInRequired(host: String)
    case inserted
    case alreadyInNotes
    case notFound(status: Int)
    case failed(TicketPageFailure)
    case notesFull
    case notesUnreadable
    /// The tab went before its page was read.
    case interrupted

    /// Whether this ticket is done with, one way or another, and Retry has nothing to do for it.
    var isSettled: Bool {
      switch self {
      case .inserted, .alreadyInNotes: return true
      default: return false
      }
    }

    var isUnderWay: Bool {
      switch self {
      case .waiting, .reading, .signInRequired: return true
      default: return false
      }
    }
  }

  public struct Entry: Identifiable, Hashable, Sendable {
    public let rank: Int
    public let ticket: TicketRecognition
    public var state: State

    public var id: Int { rank }
  }

  /// What a test of an address in the settings gave.
  public enum TestResult: Hashable, Sendable {
    case notRecognized
    case recognized(
      TicketRecognition, resolverName: String, outcome: TicketPageOutcome?, line: String?)
  }

  /// Per session, for the length of the run: what the notes pane says.
  public private(set) var entries: [SessionID: [Entry]] = [:]
  /// The resolvers, as stored, in their order.
  public private(set) var resolvers: [TicketResolver] = []
  /// Why the resolvers could not be read or written, until it is dealt with.
  public private(set) var storeError: String?
  public private(set) var isLoaded = false

  public var insertsTicketTitles: Bool {
    didSet { preferences.insertsTicketTitles = insertsTicketTitles }
  }

  public var lineFormat: TicketLineFormat {
    didSet {
      guard lineFormat.isValid else { return }
      preferences.lineFormat = lineFormat
    }
  }

  /// Whether pages can be read at all: a workspace without a web view reads none.
  public var canReadPages: Bool { reader != nil }

  @ObservationIgnored private let repository: any TicketResolverRepository
  @ObservationIgnored private let preferences: any TicketTitlePreferences
  @ObservationIgnored private let notes: NotesModel
  @ObservationIgnored private weak var reader: (any TicketPageReading)?
  @ObservationIgnored private var loading: Task<Void, Never>?
  @ObservationIgnored private var tasks: [SessionID: [Task<Void, Never>]] = [:]
  /// The set a session's tickets were recognised with, so that Retry reads them with it.
  @ObservationIgnored private var sets: [SessionID: TicketResolverSet] = [:]

  public init(
    repository: any TicketResolverRepository,
    preferences: any TicketTitlePreferences,
    notes: NotesModel,
    reader: (any TicketPageReading)?
  ) {
    self.repository = repository
    self.preferences = preferences
    self.notes = notes
    self.reader = reader
    insertsTicketTitles = preferences.insertsTicketTitles
    lineFormat = preferences.lineFormat
  }

  // MARK: - Resolvers

  /// Reads the resolvers, once.
  public func load() async {
    if let loading {
      await loading.value
      return
    }
    let task = Task { await self.read() }
    loading = task
    await task.value
  }

  private func read() async {
    do {
      resolvers = try await repository.document().current
      storeError = nil
    } catch {
      // The shipped presets meanwhile: a file that cannot be read is not a reason to stop.
      resolvers = TicketResolverPresets.all
      storeError = error.localizedDescription
    }
    isLoaded = true
  }

  /// The resolvers a creation recognises tickets with, or `nil` when titles are off, or when no
  /// page can be read.
  public func activeResolvers() async -> TicketResolverSet? {
    guard insertsTicketTitles, reader != nil else { return nil }
    await load()
    let set = TicketResolverSet(resolvers)
    return set.isEmpty ? nil : set
  }

  /// Writes the resolvers, in this order. A preset whose rules differ from the shipped ones is
  /// marked as the user's from then on.
  @discardableResult
  public func save(_ resolvers: [TicketResolver]) async -> Bool {
    let marked = resolvers.map(TicketResolverPresets.markingChanges)
    do {
      try await repository.save(marked)
      self.resolvers = marked
      storeError = nil
      return true
    } catch {
      storeError = error.localizedDescription
      return false
    }
  }

  public var fileURL: URL? { repository.fileURL }

  // MARK: - A session's tickets

  /// Starts reading the tickets a session was created with. Returns at once: the pages are read
  /// in the background, one after the other, and each title goes to the notes as it comes.
  public func start(_ tickets: [TicketRecognition], for id: SessionID) {
    guard !tickets.isEmpty, reader != nil, insertsTicketTitles else { return }
    let set = TicketResolverSet(resolvers)
    sets[id] = set
    let entries = tickets.enumerated().map {
      Entry(rank: $0.offset, ticket: $0.element, state: .waiting)
    }
    self.entries[id] = entries
    run(entries, resolvers: set, for: id)
  }

  /// Reads again the tickets whose line is not in the notes.
  public func retry(_ id: SessionID) {
    guard let set = sets[id], let current = entries[id] else { return }
    cancel(id)
    let pending = current.filter { !$0.state.isSettled }
    guard !pending.isEmpty else { return }
    for entry in pending { update(entry.rank, to: .waiting, for: id) }
    run(pending, resolvers: set, for: id)
  }

  /// Show Tab: the ticket's tab in front, in a web view shown.
  public func showTicket(_ entry: Entry, in id: SessionID) {
    guard let reader, let set = sets[id] else { return }
    reader.showTicket(entry.ticket, resolvers: set, in: id)
  }

  /// The session is gone: nothing more is read for it.
  public func forget(_ id: SessionID) {
    cancel(id)
    entries[id] = nil
    sets[id] = nil
  }

  private func cancel(_ id: SessionID) {
    for task in tasks[id] ?? [] { task.cancel() }
    tasks[id] = nil
  }

  /// One ticket at a time, so that a session naming five tickets does not load five pages at
  /// once. A ticket whose site asks to sign in lets the next one start: it waits for the user,
  /// on a light page, without holding the others.
  private func run(_ entries: [Entry], resolvers: TicketResolverSet, for id: SessionID) {
    guard let reader else { return }
    let driver = Task { [weak self] in
      for entry in entries {
        guard !Task.isCancelled, let self else { return }
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
          let once = OnceGate(gate)
          let reading = Task { [weak self] in
            let outcome = await reader.readTicket(entry.ticket, resolvers: resolvers, in: id) {
              progress in
              guard let self else { return }
              switch progress {
              case .loading:
                self.update(entry.rank, to: .reading, for: id)
              case .signInRequired(let host):
                self.update(entry.rank, to: .signInRequired(host: host), for: id)
                once.open()
              case .notFound(let status):
                self.update(entry.rank, to: .notFound(status: status), for: id)
                once.open()
              }
            }
            await self?.finish(entry, outcome: outcome, for: id)
            once.open()
          }
          self.tasks[id, default: []].append(reading)
        }
      }
    }
    tasks[id, default: []].append(driver)
  }

  private func finish(_ entry: Entry, outcome: TicketPageOutcome, for id: SessionID) async {
    // Forgotten meanwhile — archived: its notes are not written to any more.
    guard !Task.isCancelled, entries[id] != nil else { return }
    let state: State
    switch outcome {
    case .title(let title, _):
      let line = lineFormat.line(id: entry.ticket.shortID, title: title, url: entry.ticket.address)
      switch await notes.insertTicketLine(
        line, address: entry.ticket.address, rank: entry.rank, for: id)
      {
      case .inserted: state = .inserted
      case .alreadyThere: state = .alreadyInNotes
      case .notesFull: state = .notesFull
      case .unreadable: state = .notesUnreadable
      }
    case .signInRequired(let host): state = .signInRequired(host: host)
    case .notFound(let status): state = .notFound(status: status)
    case .failed(let failure): state = .failed(failure)
    case .abandoned: state = .interrupted
    }
    update(entry.rank, to: state, for: id)
  }

  private func update(_ rank: Int, to state: State, for id: SessionID) {
    guard let index = entries[id]?.firstIndex(where: { $0.rank == rank }) else { return }
    entries[id]?[index].state = state
  }

  // MARK: - The settings' test

  /// What `address` would give, read with `resolvers` — the saved ones, or those being edited —
  /// whether titles are on or not: the test is asked for.
  public func test(_ address: String, with resolvers: [TicketResolver]) async -> TestResult {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let set = TicketResolverSet(resolvers)
    guard let ticket = set.recognize(address) else { return .notRecognized }
    let name = set.resolver(id: ticket.resolverID)?.resolver.trimmedName ?? ""
    guard let reader else {
      return .recognized(ticket, resolverName: name, outcome: nil, line: nil)
    }
    let outcome = await reader.testTicketPage(ticket, resolvers: set)
    var line: String?
    if case .title(let title, _) = outcome {
      line = lineFormat.line(id: ticket.shortID, title: title, url: ticket.address)
    }
    return .recognized(ticket, resolverName: name, outcome: outcome, line: line)
  }
}

/// Lets a waiting caller go once, whichever of two events comes first.
@MainActor
private final class OnceGate {
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}
