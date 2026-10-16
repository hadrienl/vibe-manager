import Foundation

/// One of the application's tool servers, as an agent sees it: its name, what it says of itself, and
/// its tools (#69, #352).
///
/// Every server shares the one channel and the one bridge: the bridge names its server when it says
/// hello, and the application answers with that server's tools, for the sessions that server lets in.
/// Known to the bridge as well, which lists a server's tools by itself while the application is
/// closed.
public struct AgentToolServerDefinition: Sendable {
  public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
      self.name = name
      self.description = description
      self.inputSchema = inputSchema
    }
  }

  /// The name the agent knows the server by, and prefixes its tools with.
  public let name: String
  /// Given to the agent at `initialize`.
  public let instructions: String
  public let tools: [Tool]
  /// What a call answers while the application is closed.
  public let closedMessage: String
  /// What a process the server does not let in is told.
  public let refusal: String

  public init(
    name: String, instructions: String, tools: [Tool], closedMessage: String, refusal: String
  ) {
    self.name = name
    self.instructions = instructions
    self.tools = tools
    self.closedMessage = closedMessage
    self.refusal = refusal
  }

  public func knows(tool name: String) -> Bool {
    tools.contains { $0.name == name }
  }

  /// `tools/list`'s answer.
  public var listResult: JSONValue {
    [
      "tools": .array(
        tools.map { tool in
          [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
          ]
        })
    ]
  }

  /// Every server the bridge can stand for.
  public static let all: [AgentToolServerDefinition] = [.browser, .coordination]

  /// The server a bridge names; a bridge that names none is the web view's, as every bridge was
  /// before #352 — an agent left running in the terminal host since then still says nothing.
  public static func named(_ name: String?) -> AgentToolServerDefinition? {
    guard let name else { return .browser }
    return all.first { $0.name == name }
  }

  /// The web view's tools (#69).
  public static let browser = AgentToolServerDefinition(
    name: BrowserToolCatalog.serverName,
    instructions: """
      These tools drive the web view of this Vibe Manager session, beside its terminal: open \
      a preview, reload it, read it, look at its console, click and type in it. The user sees \
      every tab and every action. Whenever the user should see a page — a preview, a document \
      or an artifact you made, a pull request, a ticket — open it with tab_open rather than in a \
      browser: it appears beside this terminal.
      """,
    tools: BrowserToolCatalog.tools.map {
      Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
    },
    closedMessage: BrowserBridge.closedMessage,
    refusal:
      "This process cannot drive a session's web view: it does not run in the terminal of a "
      + "Vibe Manager session, or agents are not given the web view (Settings › Web View).")
}
