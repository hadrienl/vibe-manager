import Foundation
import VibeDomain

/// One side terminal of a session's drawer (#43), as it is written down.
///
/// What is kept is what a restoration needs to put the tab back where it was — never a command:
/// a shell is relaunched bare in the folder it was in, and nothing is typed into it.
public struct DrawerTerminalRecord: Hashable, Codable, Sendable {
  public var id: TerminalID
  /// The name the user gave the tab, or `nil` for the automatic title.
  public var title: String?
  /// The folder the shell was last seen in.
  public var directory: String?
  public var size: TerminalSize?
  /// The title the tab showed last, so that it reads the same before its new shell has answered.
  public var lastSeenTitle: String?

  public init(
    id: TerminalID,
    title: String? = nil,
    directory: String? = nil,
    size: TerminalSize? = nil,
    lastSeenTitle: String? = nil
  ) {
    self.id = id
    self.title = title
    self.directory = directory
    self.size = size
    self.lastSeenTitle = lastSeenTitle
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, directory, size, lastSeenTitle
  }

  /// The identifier is written as the plain UUID string it is, like the runtime document's: a
  /// synthesized encoding would nest it under `rawValue`, which reads as a mistake in a document
  /// meant to be openable by hand.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: TerminalID(rawValue: try container.decode(UUID.self, forKey: .id)),
      title: try container.decodeIfPresent(String.self, forKey: .title),
      directory: try container.decodeIfPresent(String.self, forKey: .directory),
      size: try container.decodeIfPresent(TerminalSize.self, forKey: .size),
      lastSeenTitle: try container.decodeIfPresent(String.self, forKey: .lastSeenTitle)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id.rawValue, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(directory, forKey: .directory)
    try container.encodeIfPresent(size, forKey: .size)
    try container.encodeIfPresent(lastSeenTitle, forKey: .lastSeenTitle)
  }
}

/// A session's drawer of side terminals, as it is written down: `drawer.json`, beside the store
/// and never inside it. The folder a shell is in, the tab in front and the drawer's height change
/// all the time, and each change written into `sessions.json` would rewrite it — and could touch
/// `updatedAt`, which orders the sessions by when they were last worked in.
public struct SessionTerminalsDocument: Hashable, Codable, Sendable {
  public static let currentSchema = 1

  public var schema: Int
  public var isVisible: Bool
  public var height: Double
  public var activeTerminal: TerminalID?
  /// In the order of the tabs.
  public var terminals: [DrawerTerminalRecord]

  public init(
    isVisible: Bool = false,
    height: Double = SessionTerminalsDocument.defaultHeight,
    activeTerminal: TerminalID? = nil,
    terminals: [DrawerTerminalRecord] = []
  ) {
    schema = Self.currentSchema
    self.isVisible = isVisible
    self.height = height
    self.activeTerminal = activeTerminal
    self.terminals = terminals
  }

  /// The height of a drawer shown for the first time, in points.
  public static let defaultHeight: Double = 240
  /// The height a drawer can be given. The upper bound is relative — 70 % of what the session
  /// shows — and applied by the view; this one only keeps a document edited by hand sensible.
  public static let heightRange: ClosedRange<Double> = 120...2_000
  /// How many side terminals one session opens at most: the terminal host runs 64 at once,
  /// agents included, and one session must not take the whole of that margin.
  public static let maximumTerminalCount = 8

  private enum CodingKeys: String, CodingKey {
    case schema, isVisible, height, activeTerminal, terminals
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(Int.self, forKey: .schema)
    isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
    let height = try container.decodeIfPresent(Double.self, forKey: .height) ?? Self.defaultHeight
    self.height = min(max(height, Self.heightRange.lowerBound), Self.heightRange.upperBound)
    activeTerminal = try container.decodeIfPresent(UUID.self, forKey: .activeTerminal)
      .map(TerminalID.init(rawValue:))
    terminals =
      try container.decodeIfPresent([DrawerTerminalRecord].self, forKey: .terminals)
      ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(isVisible, forKey: .isVisible)
    try container.encode(height, forKey: .height)
    try container.encode(activeTerminal?.rawValue, forKey: .activeTerminal)
    try container.encode(terminals, forKey: .terminals)
  }
}

/// Where each session's drawer is kept: its document, and the history each of its terminals
/// showed (ADR 0027).
///
/// The history is the one piece of terminal output the application ever writes to disk, and only
/// for the side terminals: bounded as it is in memory, private to the user, kept out of backups
/// and out of the diagnostics.
public protocol SessionTerminalsStore: Sendable {
  /// `nil` when the session has no drawer yet, or its document cannot be read.
  func load(_ session: SessionID) async -> SessionTerminalsDocument?
  func save(_ document: SessionTerminalsDocument, for session: SessionID) async
  func loadScrollback(of terminal: TerminalID, in session: SessionID) async -> [UInt8]?
  func saveScrollback(_ bytes: [UInt8], of terminal: TerminalID, in session: SessionID) async
  func removeScrollback(of terminal: TerminalID, in session: SessionID) async
  /// Every history of every session: keeping them was turned off.
  func removeAllScrollback() async
  /// Everything the session's drawer left: the session is gone.
  func remove(_ session: SessionID) async
  /// What the histories weigh on disk, for the diagnostics, which never read one.
  func scrollbackByteCount() async -> Int
}

/// Keeps the drawers for the run, for a workspace assembled without a disk.
public actor InMemorySessionTerminalsStore: SessionTerminalsStore {
  private var documents: [SessionID: SessionTerminalsDocument]
  private var scrollbacks: [TerminalID: [UInt8]] = [:]
  private var owners: [TerminalID: SessionID] = [:]

  public init(documents: [SessionID: SessionTerminalsDocument] = [:]) {
    self.documents = documents
  }

  public func load(_ session: SessionID) -> SessionTerminalsDocument? {
    documents[session]
  }

  public func save(_ document: SessionTerminalsDocument, for session: SessionID) {
    documents[session] = document
  }

  public func loadScrollback(of terminal: TerminalID, in session: SessionID) -> [UInt8]? {
    scrollbacks[terminal]
  }

  public func saveScrollback(_ bytes: [UInt8], of terminal: TerminalID, in session: SessionID) {
    scrollbacks[terminal] = bytes
    owners[terminal] = session
  }

  public func removeScrollback(of terminal: TerminalID, in session: SessionID) {
    scrollbacks[terminal] = nil
    owners[terminal] = nil
  }

  public func removeAllScrollback() {
    scrollbacks.removeAll()
    owners.removeAll()
  }

  public func remove(_ session: SessionID) {
    documents[session] = nil
    for (terminal, owner) in owners where owner == session {
      scrollbacks[terminal] = nil
      owners[terminal] = nil
    }
  }

  public func scrollbackByteCount() -> Int {
    scrollbacks.values.reduce(0) { $0 + $1.count }
  }
}
