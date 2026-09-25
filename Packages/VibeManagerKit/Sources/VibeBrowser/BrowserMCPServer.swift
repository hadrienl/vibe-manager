import Foundation
import VibeDomain

/// What a tool gives back: text, and images.
public struct BrowserToolResult: Hashable, Sendable {
  public enum Content: Hashable, Sendable {
    case text(String)
    case image(Data, mimeType: String)
  }

  public var content: [Content]
  public var isError: Bool

  public init(content: [Content], isError: Bool = false) {
    self.content = content
    self.isError = isError
  }

  public static func text(_ text: String) -> Self {
    Self(content: [.text(text)])
  }

  public static func error(_ text: String) -> Self {
    Self(content: [.text(text)], isError: true)
  }

  var json: JSONValue {
    [
      "content": .array(
        content.map { item in
          switch item {
          case .text(let text):
            return ["type": "text", "text": .string(text)]
          case .image(let data, let mimeType):
            return [
              "type": "image", "data": .string(data.base64EncodedString()),
              "mimeType": .string(mimeType),
            ]
          }
        }),
      "isError": .bool(isError),
    ]
  }
}

/// Runs one tool for one session.
@MainActor
public protocol BrowserToolRunning: AnyObject {
  func run(tool: String, arguments: JSONValue, session: SessionID) async -> BrowserToolResult
}

/// The Model Context Protocol, as far as a server of tools speaks it: JSON-RPC 2.0, one message per
/// line (#69).
///
/// Stateless on purpose. A bridge that reconnects after the application was relaunched carries on
/// without saying `initialize` again, and is answered as if it had.
public enum BrowserMCPServer {
  public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

  /// The answer to one line, or `nil` for a notification, which is not answered.
  @MainActor
  public static func respond(
    to line: Data, session: SessionID, runner: any BrowserToolRunning
  ) async -> Data? {
    guard let message = try? JSONDecoder().decode(JSONValue.self, from: line),
      case .object(let object) = message
    else {
      return encode(error: -32700, message: "Parse error", id: .null)
    }
    let id = object["id"]
    guard let method = object["method"]?.stringValue else {
      // A response to something this server never asks: ignored.
      return id == nil ? nil : encode(error: -32600, message: "Invalid Request", id: id ?? .null)
    }
    guard let id else { return nil }
    let parameters = object["params"] ?? [:]
    switch method {
    case "initialize":
      let requested = parameters["protocolVersion"]?.stringValue
      let version =
        requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
        ?? supportedProtocolVersions[0]
      return encode(result: initializeResult(version: version), id: id)
    case "ping":
      return encode(result: [:], id: id)
    case "tools/list":
      return encode(result: BrowserToolCatalog.listResult, id: id)
    case "tools/call":
      guard let name = parameters["name"]?.stringValue else {
        return encode(error: -32602, message: "Missing tool name", id: id)
      }
      guard BrowserToolCatalog.tool(named: name) != nil else {
        return encode(error: -32602, message: "Unknown tool: \(name)", id: id)
      }
      let result = await runner.run(
        tool: name, arguments: parameters["arguments"] ?? [:], session: session)
      return encode(result: result.json, id: id)
    case "resources/list":
      return encode(result: ["resources": []], id: id)
    case "prompts/list":
      return encode(result: ["prompts": []], id: id)
    default:
      return encode(error: -32601, message: "Method not found: \(method)", id: id)
    }
  }

  public static func initializeResult(version: String) -> JSONValue {
    [
      "protocolVersion": .string(version),
      "capabilities": ["tools": ["listChanged": false]],
      "serverInfo": ["name": .string(BrowserToolCatalog.serverName), "version": "1"],
      "instructions": """
      These tools drive the web view of this Vibe Manager session, beside its terminal: open \
      a preview, reload it, read it, look at its console, click and type in it. The user sees \
      every tab and every action. Whenever the user should see a page — a preview, a document \
      or an artifact you made, a pull request, a ticket — open it with tab_open rather than in a \
      browser: it appears beside this terminal.
      """,
    ]
  }

  public static func encode(result: JSONValue, id: JSONValue) -> Data {
    line(["jsonrpc": "2.0", "id": id, "result": result])
  }

  public static func encode(error code: Int, message: String, id: JSONValue) -> Data {
    line([
      "jsonrpc": "2.0", "id": id,
      "error": ["code": .number(Double(code)), "message": .string(message)],
    ])
  }

  static func line(_ value: JSONValue) -> Data {
    Data(value.jsonText.utf8) + Data([0x0A])
  }
}
