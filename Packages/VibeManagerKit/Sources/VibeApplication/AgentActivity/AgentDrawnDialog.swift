import Foundation

/// What a CLI says of a dialog it has just drawn (#273), enough to tell which reported request it
/// is: Codex's notification quotes the start of a command, a file, or an MCP server.
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
  }

  public let subject: Subject

  public init(_ subject: Subject) {
    self.subject = subject
  }

  /// Whether `request` is the one whose dialog this is.
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
    default:
      return false
    }
  }

  /// A server named in a tool's name (`prisme_ai_builder`) and in a dialog (`prisme-ai-builder`).
  static func serverKey(_ name: String) -> String {
    name.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}
