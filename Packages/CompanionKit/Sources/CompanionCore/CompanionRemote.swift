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
  /// The project's icon the session wears instead, named by its content: the phone asks for its
  /// PNG once (`icon`) and keeps it.
  public var iconID: String?

  public init(symbol: String, color: String, iconID: String? = nil) {
    self.symbol = symbol
    self.color = color
    self.iconID = iconID
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

/// An agent a new session can run, with its models.
public struct RemoteAgent: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var models: [RemoteModel]

  public init(id: String, name: String, models: [RemoteModel]) {
    self.id = id
    self.name = name
    self.models = models
  }
}

public struct RemoteModel: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var isDefault: Bool

  public init(id: String, name: String, isDefault: Bool) {
    self.id = id
    self.name = name
    self.isDefault = isDefault
  }
}

/// A prompt template of the Mac: what picking it fills in.
public struct RemoteTemplate: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var body: String
  public var folder: String?
  public var appearance: RemoteAppearance?

  public init(
    id: String, name: String, body: String, folder: String?, appearance: RemoteAppearance?
  ) {
    self.id = id
    self.name = name
    self.body = body
    self.folder = folder
    self.appearance = appearance
  }
}

/// What the New Session sheet offers: the recent folders, the agents, the icons' symbols and
/// colours of the Settings, the prompt templates.
public struct RemoteNewSessionOptions: Codable, Hashable, Sendable {
  public var folders: [String]
  public var agents: [RemoteAgent]
  public var symbols: [String]
  public var colors: [String]
  public var templates: [RemoteTemplate]

  public init(
    folders: [String], agents: [RemoteAgent], symbols: [String] = [], colors: [String] = [],
    templates: [RemoteTemplate] = []
  ) {
    self.folders = folders
    self.agents = agents
    self.symbols = symbols
    self.colors = colors
    self.templates = templates
  }
}

/// A session to create, as the phone's sheet fills it.
public struct RemoteNewSession: Codable, Hashable, Sendable {
  public var name: String
  public var folder: String
  public var agentID: String
  public var modelID: String?
  public var prompt: String
  /// Started at once, in En cours; or left to wait in À faire.
  public var start: Bool
  public var coordinates: Bool
  /// The icon picked; `nil` leaves it to the Mac, as for a name left empty.
  public var appearance: RemoteAppearance?

  public init(
    name: String, folder: String, agentID: String, modelID: String?, prompt: String, start: Bool,
    coordinates: Bool, appearance: RemoteAppearance? = nil
  ) {
    self.appearance = appearance
    self.name = name
    self.folder = folder
    self.agentID = agentID
    self.modelID = modelID
    self.prompt = prompt
    self.start = start
    self.coordinates = coordinates
  }
}

/// A folder of the Mac, as the phone browses it for a new session: its subfolders alone.
public struct RemoteFolderListing: Codable, Hashable, Sendable {
  public var path: String
  /// Names, sorted as the Finder sorts them.
  public var folders: [String]
  /// Why it could not be read, in words for the user.
  public var problem: String?

  public init(path: String, folders: [String], problem: String? = nil) {
    self.path = path
    self.folders = folders
    self.problem = problem
  }
}

/// A file the phone joins to a message: a photo, a document.
public struct RemoteFile: Codable, Hashable, Sendable {
  public var name: String
  public var data: Data

  public init(name: String, data: Data) {
    self.name = name
    self.data = data
  }
}

/// A tab of a session's web view.
public struct RemoteWebTab: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var url: String
  public var isLoading: Bool

  public init(id: String, title: String, url: String, isLoading: Bool) {
    self.id = id
    self.title = title
    self.url = url
    self.isLoading = isLoading
  }
}

/// A session's web view as the Mac shows it (#400): its tabs, and the active page's picture.
public struct RemoteWebState: Codable, Hashable, Sendable {
  public var sessionID: String
  public var tabs: [RemoteWebTab]
  public var activeTabID: String?
  public var canGoBack: Bool
  public var canGoForward: Bool
  /// The visible part of the page, in JPEG; `nil` when it has not changed since the last one.
  public var frame: Data?

  public init(
    sessionID: String, tabs: [RemoteWebTab], activeTabID: String?, canGoBack: Bool,
    canGoForward: Bool, frame: Data?
  ) {
    self.sessionID = sessionID
    self.tabs = tabs
    self.activeTabID = activeTabID
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.frame = frame
  }
}

/// What the phone does to the web view; the Mac's page does it.
public enum RemoteWebAction: Codable, Hashable, Sendable {
  /// A touch, in fractions of the visible page: 0…1 from its top left corner.
  case tap(x: Double, y: Double)
  /// A scroll, in fractions of the visible height.
  case scroll(dy: Double)
  /// Text typed into what has the focus; Return as `\n`.
  case type(String)
  case navigate(String)
  case back, forward, reload
  case selectTab(String)
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
  /// A message with files: they join the conversation's composer on the Mac, as dropped there.
  case sendFiles(sessionID: String, text: String, files: [RemoteFile])
  case answer(sessionID: String, requestID: String, choiceIDs: [String], text: String?)
  case setStatus(sessionID: String, status: RemoteTaskStatus)
  case search(query: String, token: Int)
  case newSessionOptions
  case createSession(RemoteNewSession)
  /// A folder's subfolders; `nil` for the user's home.
  case listFolder(path: String?)
  /// A project icon's PNG.
  case icon(id: String)
  /// Stops what the agent does, as Escape in its terminal.
  case interrupt(sessionID: String)
  /// Shows a session's web view, pictured as the Mac draws it, until `nil`.
  case showWeb(sessionID: String?)
  case web(sessionID: String, RemoteWebAction)

  // The Mac to the phone.
  case welcome(protocolVersion: Int, macName: String)
  /// Every session, whole, at the start and at each change.
  case sessions([RemoteSession])
  case conversation(RemoteConversation)
  case searchResults(token: Int, [RemoteSearchResult])
  case newSessionOffer(RemoteNewSessionOptions)
  case folderListing(RemoteFolderListing)
  case iconData(id: String, png: Data)
  case webState(RemoteWebState)
  /// The session asked for exists: the phone shows it.
  case created(sessionID: String)
  /// What the Mac could not do of what was asked, in words for the user.
  case failure(String)
}

/// The channel's frames: a big-endian `u32` length and the message as JSON — the application's link
/// without its kind byte, a stream carrying nothing else.
public enum RemoteFrame {
  /// A conversation of a long session, whole, fits; a corrupt length cannot make an end allocate
  /// a gigabyte.
  public static let maximumLength = 32 << 20

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
