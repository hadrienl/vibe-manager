import Foundation

/// What the phone and the Mac say over the direct channel (#399, #400): the phone drives the Mac's
/// sessions as the Mac's own window does. Plain values, framed as the application's link is.
public enum CompanionRemote {
  /// 2: a request carries all its questions, and `answers` answers each (#428). Both ends still
  /// read version 1: a Mac of version 1 gets `answer`, which it knows, and the phone shows a
  /// version 1 request's single question.
  public static let protocolVersion = 2
  /// Whether a Mac speaking `version` reads `answers`.
  public static func takesAnswers(_ version: Int?) -> Bool { (version ?? 1) >= 2 }
  /// The channel's protocol, offered at the iroh handshake beside the trials' echo. Unchanged by
  /// `protocolVersion`: both ends read the other's older messages.
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

/// What an agent waits for the user on, for the phone to say in its language.
public enum RemoteWait: Codable, Hashable, Sendable {
  /// A tool to allow: the command, the file — the agent's words, never translated.
  case permission(String)
  /// A question, in the agent's words.
  case question(String)
  case plan
  case other
}

/// What the Mac could not do of what the phone asked, for the phone to say in its language.
public enum RemoteFailure: Codable, Hashable, Sendable {
  case sessionGone
  case messageNotSent
  case requestGone
  case answerNotGiven
  /// The Mac cannot resume the conversation and asks the user what to do.
  case restartNeedsMac
  case folderMissing
  case noAgent
  /// The Mac's own words, already in its language: a draft it refused, a request that failed.
  case other(String)
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
  /// What it waits for the user on, when it does.
  public var waitingFor: RemoteWait?
  public var updatedAt: Date
  /// The Mac's manual order within its column, for the sort it shows.
  public var rank: Int
  /// Whether its agent ever ran: a closed one is restarted, one never started is started.
  public var hasStarted: Bool

  public init(
    id: String, name: String, folderPath: String, folderName: String, agentName: String,
    status: RemoteTaskStatus, activity: RemoteActivity, appearance: RemoteAppearance,
    coordinatorID: String? = nil, isCoordinator: Bool = false, waitingFor: RemoteWait? = nil,
    updatedAt: Date, rank: Int = 0, hasStarted: Bool = true
  ) {
    self.hasStarted = hasStarted
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
    self.waitingFor = waitingFor
    self.updatedAt = updatedAt
    self.rank = rank
  }
}

/// One choice of a permission or a question. A permission's choices are `allowOnce`,
/// `allowAlways` and `deny`, labelled by the phone; a question's carry the agent's words.
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

/// One question of a request: the agent may ask several at once (#428).
public struct RemoteQuestion: Codable, Hashable, Sendable {
  /// The agent's short tag for it — "Action", "Checks".
  public var header: String?
  public var title: String
  public var choices: [RemoteChoice]
  /// The agent takes several of the choices at once.
  public var allowsSeveral: Bool
  /// The agent takes words of the user's own besides the choices.
  public var allowsText: Bool

  public init(
    header: String? = nil, title: String, choices: [RemoteChoice], allowsSeveral: Bool = false,
    allowsText: Bool = false
  ) {
    self.header = header
    self.title = title
    self.choices = choices
    self.allowsSeveral = allowsSeveral
    self.allowsText = allowsText
  }
}

/// The answer to one question: the choices taken, or the user's own words.
public struct RemoteAnswer: Codable, Hashable, Sendable {
  public var choiceIDs: [String]
  public var text: String?

  public init(choiceIDs: [String], text: String? = nil) {
    self.choiceIDs = choiceIDs
    self.text = text
  }

  /// Whether it answers anything.
  public var isGiven: Bool {
    !choiceIDs.isEmpty || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// What the agent waits for the user on, with the choices to answer it.
///
/// A question's `title`, `subject`, `choices`, `allowsSeveral` and `allowsText` say its first
/// question, for a phone of protocol 1; `questions` says them all.
public struct RemoteRequest: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case permission, question
  }

  public var id: String
  public var kind: Kind
  /// The agent's question, or why it asks a permission; empty when it says nothing, and the phone
  /// asks in its own words.
  public var title: String
  /// The command, the file, the URL: shown in monospace.
  public var subject: String?
  public var choices: [RemoteChoice]
  /// The agent takes several of the choices at once.
  public var allowsSeveral: Bool
  /// The agent takes words of the user's own besides the choices.
  public var allowsText: Bool
  /// Every question, in order; empty for a permission, and from a Mac of protocol 1.
  public var questions: [RemoteQuestion]

  public init(
    id: String, kind: Kind, title: String, subject: String? = nil, choices: [RemoteChoice],
    allowsSeveral: Bool = false, allowsText: Bool = false, questions: [RemoteQuestion] = []
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subject = subject
    self.choices = choices
    self.allowsSeveral = allowsSeveral
    self.allowsText = allowsText
    self.questions = questions
  }

  /// A question request of its questions: the first one's words also said the way protocol 1 does.
  public init(id: String, questions: [RemoteQuestion]) {
    let first = questions.first
    self.init(
      id: id, kind: .question, title: first?.title ?? "", subject: first?.header,
      choices: first?.choices ?? [], allowsSeveral: first?.allowsSeveral ?? false,
      allowsText: first?.allowsText ?? false, questions: questions)
  }

  /// The questions to show: those listed, or the single one a Mac of protocol 1 says.
  public var shownQuestions: [RemoteQuestion] {
    guard kind == .question else { return [] }
    if !questions.isEmpty { return questions }
    return [
      RemoteQuestion(
        header: subject, title: title, choices: choices, allowsSeveral: allowsSeveral,
        allowsText: allowsText)
    ]
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, subject, choices, allowsSeveral, allowsText, questions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(Kind.self, forKey: .kind)
    title = try container.decode(String.self, forKey: .title)
    subject = try container.decodeIfPresent(String.self, forKey: .subject)
    choices = try container.decode([RemoteChoice].self, forKey: .choices)
    allowsSeveral = try container.decode(Bool.self, forKey: .allowsSeveral)
    allowsText = try container.decode(Bool.self, forKey: .allowsText)
    questions = try container.decodeIfPresent([RemoteQuestion].self, forKey: .questions) ?? []
  }
}

/// A line of a session itself, between its messages.
public enum RemoteNotice: Codable, Hashable, Sendable {
  case interrupted
  case compacted
  /// A shell command the user ran in the session.
  case shell(String)
  /// The agent's or the CLI's own words.
  case error(String)
}

/// A file that came with a message: an image the phone asks a picture of (`attachmentImage`).
public struct RemoteAttachment: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var isImage: Bool
  /// Where it is on the Mac, the key the phone asks its picture by; `nil` for an image only the
  /// transcript holds.
  public var path: String?

  public init(id: String, name: String, isImage: Bool, path: String?) {
    self.id = id
    self.name = name
    self.isImage = isImage
    self.path = path
  }
}

/// One entry of a conversation, as the Mac's conversation view shows it.
public struct RemoteEntry: Codable, Hashable, Sendable, Identifiable {
  public enum Kind: Codable, Hashable, Sendable {
    case user(String, attachments: [RemoteAttachment])
    /// The agent's words, in Markdown.
    case agent(String)
    /// A tool the agent ran, as its compact row reads: an SF Symbol, "Read Session.swift", the
    /// secondary words, and whether it still runs or failed.
    case tool(symbol: String, title: String, detail: String?, running: Bool, failed: Bool)
    /// A line of the session itself: an error, an interruption.
    case notice(RemoteNotice)
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

/// The colours a conversation is drawn with on the Mac (#274): `#RRGGBB`, or `#RRGGBBAA` when
/// translucent.
public struct RemotePalette: Codable, Hashable, Sendable {
  public var background: String
  public var surface: String
  public var raised: String
  public var text: String
  public var secondaryText: String
  public var border: String
  public var accent: String
  public var onAccent: String
  public var bubble: String
  public var bubbleText: String
  public var codeBackground: String
  public var codeText: String
  public var success: String
  public var failure: String
  public var warning: String
  public var warningBackground: String

  public init(
    background: String, surface: String, raised: String, text: String, secondaryText: String,
    border: String, accent: String, onAccent: String, bubble: String, bubbleText: String,
    codeBackground: String, codeText: String, success: String, failure: String, warning: String,
    warningBackground: String
  ) {
    self.background = background
    self.surface = surface
    self.raised = raised
    self.text = text
    self.secondaryText = secondaryText
    self.border = border
    self.accent = accent
    self.onAccent = onAccent
    self.bubble = bubble
    self.bubbleText = bubbleText
    self.codeBackground = codeBackground
    self.codeText = codeText
    self.success = success
    self.failure = failure
    self.warning = warning
    self.warningBackground = warningBackground
  }
}

/// A conversation's theme, in the light and the dark appearance: the phone draws the one its own
/// appearance asks for.
public struct RemoteTheme: Codable, Hashable, Sendable {
  public var light: RemotePalette
  public var dark: RemotePalette
  /// `system`, `serif` or `monospaced`.
  public var fontStyle: String

  public init(light: RemotePalette, dark: RemotePalette, fontStyle: String) {
    self.light = light
    self.dark = dark
    self.fontStyle = fontStyle
  }
}

/// A conversation as the phone holds it: its entries, what the agent waits for, if anything, and
/// the theme it is drawn with.
public struct RemoteConversation: Codable, Hashable, Sendable {
  public var sessionID: String
  public var entries: [RemoteEntry]
  public var request: RemoteRequest?
  public var theme: RemoteTheme?

  public init(
    sessionID: String, entries: [RemoteEntry], request: RemoteRequest? = nil,
    theme: RemoteTheme? = nil
  ) {
    self.sessionID = sessionID
    self.entries = entries
    self.request = request
    self.theme = theme
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
  /// It could not be read: macOS's privacy protection, or it went.
  public var isUnreadable: Bool

  public init(path: String, folders: [String], isUnreadable: Bool = false) {
    self.path = path
    self.folders = folders
    self.isUnreadable = isUnreadable
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

/// A session's web view as the Mac shows it (#400): its tabs, where the active one is, and how far
/// down its page is scrolled. The phone shows the same page in a web view of its own, and each side
/// tells the other what its user does there.
public struct RemoteWebState: Codable, Hashable, Sendable {
  public var sessionID: String
  public var tabs: [RemoteWebTab]
  public var activeTabID: String?
  public var canGoBack: Bool
  public var canGoForward: Bool
  /// How far down the active page is, from 0 at its top to 1 at its end.
  public var scroll: Double

  public init(
    sessionID: String, tabs: [RemoteWebTab], activeTabID: String?, canGoBack: Bool,
    canGoForward: Bool, scroll: Double
  ) {
    self.sessionID = sessionID
    self.tabs = tabs
    self.activeTabID = activeTabID
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.scroll = scroll
  }
}

/// What the phone's user does in the web view, for the Mac's to do the same.
public enum RemoteWebAction: Codable, Hashable, Sendable {
  case navigate(String)
  case back, forward, reload
  case selectTab(String)
  /// Scrolled to this fraction of the page.
  case scrollTo(Double)
}

/// A request of the phone's web view for a page only the Mac reaches — `localhost:4000` — made by
/// the Mac on its behalf.
public struct RemoteHTTPRequest: Codable, Hashable, Sendable {
  public var id: Int
  public var url: String
  public var method: String
  public var headers: [String: String]
  public var body: Data?

  public init(id: Int, url: String, method: String, headers: [String: String], body: Data?) {
    self.id = id
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

public struct RemoteHTTPResponse: Codable, Hashable, Sendable {
  public var id: Int
  public var status: Int
  public var headers: [String: String]
  public var body: Data
  /// Why there is no answer, when the Mac could not make the request.
  public var failure: String?

  public init(id: Int, status: Int, headers: [String: String], body: Data, failure: String? = nil) {
    self.id = id
    self.status = status
    self.headers = headers
    self.body = body
    self.failure = failure
  }
}

/// Whether an address is one only the Mac reaches — itself, or its local network — which the phone
/// loads through it rather than on its own.
public enum RemoteWebAddress {
  public static func isMacLocal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
      || host == "::1" || host == "[::1]" || host == "0.0.0.0"
    {
      return true
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    switch (parts[0], parts[1]) {
    case (127, _), (10, _), (192, 168): return true
    case (172, let second) where (16...31).contains(second): return true
    case (169, 254): return true
    default: return false
    }
  }

  /// The phone's own spelling of a Mac-local address: its scheme prefixed, for the web view to hand
  /// it to the channel rather than to the network.
  public static let proxiedPrefix = "vibemac-"

  public static func proxied(_ url: URL) -> URL {
    guard isMacLocal(url), let scheme = url.scheme, !scheme.hasPrefix(proxiedPrefix),
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = proxiedPrefix + scheme
    return components.url ?? url
  }

  public static func unproxied(_ url: URL) -> URL {
    guard let scheme = url.scheme, scheme.hasPrefix(proxiedPrefix),
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = String(scheme.dropFirst(proxiedPrefix.count))
    return components.url ?? url
  }

  /// What was typed in an address field: an address with its scheme, `localhost:4000` or a
  /// host, as Safari takes them.
  public static func typed(_ address: String) -> URL? {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.contains("://") { return URL(string: text) }
    let isLocal =
      text.hasPrefix("localhost") || text.hasPrefix("127.")
      || text.range(
        of: #"^[\w.-]+:\d+"#, options: .regularExpression) != nil
    return URL(string: (isLocal ? "http://" : "https://") + text)
  }

  /// What an address typed on the phone does.
  public enum Typed: Equatable, Sendable {
    /// Loaded by the phone's own web view, over the Mac's page (#457).
    case load(URL)
    /// Told to the Mac, which has no page to load it over: it opens one, the phone follows.
    case tellMac(URL)
  }

  /// What `address`, typed on the phone, does: with no page open on the Mac, the phone's web view
  /// does not exist — the Mac opens the page, never the phone later over a page of the Mac's.
  public static func typed(_ address: String, pageOpen: Bool) -> Typed? {
    guard let url = typed(address) else { return nil }
    return pageOpen ? .load(url) : .tellMac(url)
  }

  /// Two addresses for the same page: a trailing slash or a fragment changes nothing.
  public static func same(_ first: String, _ second: String) -> Bool {
    func key(_ text: String) -> String {
      var value = text.split(separator: "#", maxSplits: 1).first.map(String.init) ?? text
      while value.hasSuffix("/") { value.removeLast() }
      return value
    }
    return key(first) == key(second)
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
  /// A message with files: they join the conversation's composer on the Mac, as dropped there.
  case sendFiles(sessionID: String, text: String, files: [RemoteFile])
  /// Protocol 1's answer: a permission's choice, or a single question's.
  case answer(sessionID: String, requestID: String, choiceIDs: [String], text: String?)
  /// One answer per question, in order, for a Mac of protocol 2 (#428).
  case answers(sessionID: String, requestID: String, answers: [RemoteAnswer])
  case setStatus(sessionID: String, status: RemoteTaskStatus)
  case search(query: String, token: Int)
  case newSessionOptions
  case createSession(RemoteNewSession)
  /// A folder's subfolders; `nil` for the user's home.
  case listFolder(path: String?)
  /// A project icon's PNG.
  case icon(id: String)
  /// A folder's project icon, which a new session there wears unless another is picked.
  case folderIcon(path: String)
  /// The picture of an image joined to a message, by its path on the Mac.
  case attachmentImage(path: String)
  /// Stops what the agent does, as Escape in its terminal.
  case interrupt(sessionID: String)
  /// Stops the session's agent and keeps the rest, as the Mac's Close Session.
  case close(sessionID: String)
  /// Starts a closed session's agent again, resuming its conversation, as the Mac's Restart does.
  case restart(sessionID: String)
  /// Shows a session's web view, pictured as the Mac draws it, until `nil`.
  case showWeb(sessionID: String?)
  case web(sessionID: String, RemoteWebAction)
  case httpRequest(RemoteHTTPRequest)

  // The Mac to the phone.
  case welcome(protocolVersion: Int, macName: String)
  /// Every session, whole, at the start and at each change.
  case sessions([RemoteSession])
  case conversation(RemoteConversation)
  case searchResults(token: Int, [RemoteSearchResult])
  case newSessionOffer(RemoteNewSessionOptions)
  case folderListing(RemoteFolderListing)
  case iconData(id: String, png: Data)
  case attachmentData(path: String, jpeg: Data)
  /// `nil` for a folder without one.
  case folderIconData(path: String, png: Data?)
  case webState(RemoteWebState)
  case httpResponse(RemoteHTTPResponse)
  /// The session asked for exists: the phone shows it.
  case created(sessionID: String)
  /// What the Mac could not do of what was asked, in words for the user.
  case failure(RemoteFailure)
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
