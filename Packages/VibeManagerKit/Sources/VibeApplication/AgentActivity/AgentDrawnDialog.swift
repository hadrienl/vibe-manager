import Foundation

/// What a CLI says of a dialog it has just drawn (#273), enough to tell which reported request it
/// is: Codex's notification quotes the start of a command, a file, or an MCP server — and the
/// dialog itself, read off the screen, shows all of what it asks (#283).
public struct AgentDrawnDialog: Hashable, Sendable {
  public enum Subject: Hashable, Sendable {
    /// A command starting with this, as its report gives it: the dialog quoted it cut short.
    case commandStart(String)
    /// This command, quoted whole (#280).
    case command(String)
    /// A patch touching this file.
    case file(String)
    /// A patch touching several files.
    case files
    /// A tool of this MCP server.
    case server(String)
    /// This command, as the dialog shows it: wrapped to the terminal's width, where a line may
    /// break inside a word or in place of a space (#283).
    case shownCommand(String)
    /// A patch writing to these paths, absolute, as the dialog shows them: wrapped as a command.
    case patch(Set<String>)
    /// An access to this host.
    case host(String)
  }

  public let subject: Subject

  public init(_ subject: Subject) {
    self.subject = subject
  }

  /// Whether the dialog quotes all of what it asks: only then can it name one request for sure
  /// (#280). The start of a command, a file's name or a server's may be another request's; what
  /// the dialog shows on screen is all of it (#283).
  public var quotesWhole: Bool {
    switch subject {
    case .commandStart, .file, .files, .server: return false
    case .command, .shownCommand, .patch, .host: return true
    }
  }

  /// Whether `request` is the one whose dialog this is, or may be.
  public func matches(_ request: AgentRequest) -> Bool {
    guard case .permission(let permission) = request.content else { return false }
    switch (subject, permission.tool) {
    case (.commandStart(let start), .shell):
      return !start.isEmpty && permission.subject?.hasPrefix(start) == true
    case (.command(let command), .shell):
      return !command.isEmpty && permission.subject == command
    case (.file(let file), .patch):
      // Whole path components: `Model.swift` is not `App/SubModel.swift` (#280).
      return !file.isEmpty
        && permission.subject?.split(separator: "\n").contains {
          $0 == file || $0.hasSuffix("/" + file)
        } == true
    case (.files, .patch):
      return true
    case (.server(let name), .mcp(let server, _)):
      return Self.serverKey(name) == Self.serverKey(server)
    case (.shownCommand(let command), .shell):
      // A network access is drawn without its command (#283).
      guard permission.purpose?.hasPrefix(Self.networkPurpose) != true,
        let subject = permission.subject
      else { return false }
      return Self.fits(subject, shownAs: command)
    case (.patch(let destinations), .patch):
      let shown = Set(destinations.map(Self.withoutBlanks))
      return !shown.isEmpty
        && Set(Self.paths(of: permission).map(Self.withoutBlanks)) == shown
    case (.host(let host), .shell):
      guard let purpose = permission.purpose, purpose.hasPrefix(Self.networkPurpose) else {
        return false
      }
      let target = Self.host(of: String(purpose.dropFirst(Self.networkPurpose.count)))
      let shown = Self.host(of: host)
      return !shown.isEmpty && target == shown
    default:
      return false
    }
  }

  /// What a network access says it is for, in Codex's report: `network-access <target>`.
  static let networkPurpose = "network-access "

  /// A text with every blank taken out: what is left once a terminal has wrapped it.
  static func withoutBlanks(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
  }

  /// Whether `command` is what the dialog shows over `shown`'s lines: each line word for word,
  /// blank for blank, and between two of them nothing, or only blanks — a line wrapped inside a
  /// word, in place of a space, a newline of the command itself, its indent taken off.
  static func fits(_ command: String, shownAs shown: String) -> Bool {
    let lines = shown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    let pattern =
      #"\A\s*"# + lines.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s*"#)
      + #"\s*\z"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    return expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command))
      != nil
  }

  /// The files a patch writes to, made absolute against its working directory as Codex shows
  /// them: `notes.txt` in `/proj` is `/proj/notes.txt`.
  static func paths(of permission: AgentToolPermission) -> [String] {
    let files = permission.subject?.split(separator: "\n").map(String.init) ?? []
    return files.map { file in
      if file.hasPrefix("/") { return URL(fileURLWithPath: file).standardized.path }
      guard let directory = permission.workingDirectory else { return file }
      return URL(fileURLWithPath: directory).appendingPathComponent(file).standardized.path
    }
  }

  /// The host of a network target: `https://example.org:443/x` is `example.org`, `[::1]:80` is
  /// `::1`.
  static func host(of target: String) -> String {
    var rest = Substring(target.trimmingCharacters(in: .whitespaces))
    if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
    if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
      return rest[rest.index(after: rest.startIndex)..<close].lowercased()
    }
    if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
      rest = rest.dropFirst().dropLast()
    }
    rest = rest.prefix { $0 != "/" && $0 != ":" }
    return rest.lowercased()
  }

  /// A server named in a tool's name (`prisme_ai_builder`) and in a dialog (`prisme-ai-builder`).
  static func serverKey(_ name: String) -> String {
    name.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}
