import Foundation

/// What the phone and the Mac say over the direct channel (#399, #400): the phone drives the Mac's
/// sessions as the Mac's own window does. Plain values, framed as the application's link is.
public enum CompanionRemote {
  public static let protocolVersion = 1
  /// The channel's protocol, offered at the iroh handshake beside the trials' echo.
  public static let alpn = "vibe-manager/remote/1"
}

/// The column a session sits in, as the Mac's sidebar filters them.
public enum RemoteTaskStatus: String, Codable, Hashable, Sendable, CaseIterable {
  case todo, doing, waiting, done, archived
}

/// What the session's agent does now.
public enum RemoteActivity: String, Codable, Hashable, Sendable {
  /// Generating, running a tool.
  case working
  /// Stopped on a permission or a question: the user is expected.
  case needsAttention
  /// Waiting for an instruction.
  case idle
  /// No agent running: closed, never started, or exited.
  case stopped
}

/// The session's badge: a symbol on a colour, or the project's icon.
public struct RemoteAppearance: Codable, Hashable, Sendable {
  /// An SF Symbol name, the same on both platforms.
  public var symbol: String
  /// `#RRGGBB`.
  public var color: String
  /// The project's icon as PNG, small, when the session wears it.
  public var projectIcon: Data?

  public init(symbol: String, color: String, projectIcon: Data? = nil) {
    self.symbol = symbol
    self.color = color
    self.projectIcon = projectIcon
  }
}

/// One session of the Mac, as its sidebar shows it.
public struct RemoteSession: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  /// The folder the sidebar groups it under, as a path; `folderName` is what it says.
  public var folderPath: String
  public var folderName: String
  public var agentName: String
  public var status: RemoteTaskStatus
  public var activity: RemoteActivity
  public var appearance: RemoteAppearance
  /// The coordinator this session works for, when one created it.
  public var coordinatorID: String?
  public var isCoordinator: Bool
  /// The last thing it did or asked, on one line: "Permission : lancer xcodebuild".
  public var detail: String?
  public var updatedAt: Date
  /// The Mac's manual order within its column, for the sort it shows.
  public var rank: Int

  public init(
    id: String, name: String, folderPath: String, folderName: String, agentName: String,
    status: RemoteTaskStatus, activity: RemoteActivity, appearance: RemoteAppearance,
    coordinatorID: String? = nil, isCoordinator: Bool = false, detail: String? = nil,
    updatedAt: Date, rank: Int = 0
  ) {
    self.id = id
    self.name = name
    self.folderPath = folderPath
    self.folderName = folderName
    self.agentName = agentName
    self.status = status
    self.activity = activity
    self.appearance = appearance
    self.coordinatorID = coordinatorID
    self.isCoordinator = isCoordinator
    self.detail = detail
    self.updatedAt = updatedAt
    self.rank = rank
  }
}

/// One choice of a permission or a question.
public struct RemoteChoice: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var label: String
  public var detail: String?
  /// Refusing, stopping: shown in red.
  public var isDestructive: Bool

  public init(id: String, label: String, detail: String? = nil, isDestructive: Bool = false) {
    self.id = id
    self.label = label
    self.detail = detail
    self.isDestructive = isDestructive
  }
}

/// What the agent waits for the user on, with the choices to answer it.
public struct RemoteRequest: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case permission, question
  }

  public var id: String
  public var kind: Kind
  /// "Autoriser cette commande ?", or the agent's question.
  public var title: String
  /// The command, the file, the URL: shown in monospace.
  public var subject: String?
  public var choices: [RemoteChoice]
  /// The agent takes several of the choices at once.
  public var allowsSeveral: Bool
  /// The agent takes words of the user's own besides the choices.
  public var allowsText: Bool

  public init(
    id: String, kind: Kind, title: String, subject: String? = nil, choices: [RemoteChoice],
    allowsSeveral: Bool = false, allowsText: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subject = subject
    self.choices = choices
    self.allowsSeveral = allowsSeveral
    self.allowsText = allowsText
  }
}

/// One entry of a conversation, as the Mac's conversation view shows it.
public struct RemoteEntry: Codable, Hashable, Sendable, Identifiable {
  public enum Kind: Codable, Hashable, Sendable {
    case user(String)
    /// The agent's words, in Markdown.
    case agent(String)
    /// A tool the agent ran, as its compact row reads: an SF Symbol, "Read Session.swift", the
    /// secondary words, and whether it still runs or failed.
    case tool(symbol: String, title: String, detail: String?, running: Bool, failed: Bool)
    /// A line of the session itself: started, stopped, an error.
    case notice(String)
  }

  public var id: String
  public var kind: Kind
  public var date: Date?

  public init(id: String, kind: Kind, date: Date? = nil) {
    self.id = id
    self.kind = kind
    self.date = date
  }
}

/// A conversation as the phone holds it: its entries, and what the agent waits for, if anything.
public struct RemoteConversation: Codable, Hashable, Sendable {
  public var sessionID: String
  public var entries: [RemoteEntry]
  public var request: RemoteRequest?

  public init(sessionID: String, entries: [RemoteEntry], request: RemoteRequest? = nil) {
    self.sessionID = sessionID
    self.entries = entries
    self.request = request
  }
}

/// A row of the search, as ⌘P lists it: the session and why it is there.
public struct RemoteSearchResult: Codable, Hashable, Sendable, Identifiable {
  public var id: String { sessionID }
  public var sessionID: String
  public var reason: String?
  public var isArchived: Bool

  public init(sessionID: String, reason: String?, isArchived: Bool) {
    self.sessionID = sessionID
    self.reason = reason
    self.isArchived = isArchived
  }
}

/// Everything either end of the channel says.
public enum RemoteMessage: Codable, Equatable, Sendable {
  // The phone to the Mac.
  /// First, once per connection.
  case hello(protocolVersion: Int, deviceName: String)
  /// Shows a conversation: the Mac sends it whole, then again at each change, until another is
  /// shown or `nil`.
  case show(sessionID: String?)
  case send(sessionID: String, text: String)
  case answer(sessionID: String, requestID: String, choiceIDs: [String], text: String?)
  case setStatus(sessionID: String, status: RemoteTaskStatus)
  case search(query: String, token: Int)

  // The Mac to the phone.
  case welcome(protocolVersion: Int, macName: String)
  /// Every session, whole, at the start and at each change.
  case sessions([RemoteSession])
  case conversation(RemoteConversation)
  case searchResults(token: Int, [RemoteSearchResult])
  /// What the Mac could not do of what was asked, in words for the user.
  case failure(String)
}

/// The channel's frames: a big-endian `u32` length and the message as JSON — the application's link
/// without its kind byte, a stream carrying nothing else.
public enum RemoteFrame {
  /// A conversation of a long session, whole, fits; a corrupt length cannot make an end allocate
  /// a gigabyte.
  public static let maximumLength = 8 << 20

  public static func encode(_ message: RemoteMessage) -> Data {
    let payload = (try? JSONEncoder().encode(message)) ?? Data()
    let length = UInt32(payload.count)
    var data = Data([
      UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
    data.append(payload)
    return data
  }

  public enum Failure: Error, Equatable {
    case tooLong(Int)
  }

  /// Cuts a byte stream into messages; what is incomplete waits for the next read, and a frame that
  /// does not decode — a newer message — is skipped.
  public struct Decoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [RemoteMessage] {
      buffer.append(bytes)
      var messages: [RemoteMessage] = []
      while buffer.count >= 4 {
        let start = buffer.startIndex
        let length =
          Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8
          | Int(buffer[start + 3])
        guard length <= RemoteFrame.maximumLength else { throw Failure.tooLong(length) }
        guard buffer.count >= 4 + length else { break }
        let payload = buffer.subdata(in: start + 4..<start + 4 + length)
        if let message = try? JSONDecoder().decode(RemoteMessage.self, from: payload) {
          messages.append(message)
        }
        buffer.removeSubrange(start..<start + 4 + length)
      }
      return messages
    }
  }
}
