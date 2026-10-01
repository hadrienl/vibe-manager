import Foundation
import VibeEndpoints

// The gateway of #107 on the command line, for the benchmark and for trying an endpoint by hand:
//
//   vibe-gateway --base-url https://openrouter.ai/api/v1 --protocol chatCompletions \
//     --model qwen/qwen3-coder --secret-env OPENROUTER_API_KEY [--port 0]
//
// It prints one line, `ANTHROPIC_BASE_URL=… ANTHROPIC_AUTH_TOKEN=…`, then serves until killed.
// The secret is read from the environment variable named, never from the command line, where
// every process of the user could read it.

struct Options {
  var baseURL: URL?
  var wireProtocol = EndpointWireProtocol.chatCompletions
  var model: String?
  var secretVariable: String?
  var authentication = EndpointAuthentication.bearer
  var port: UInt16 = 0
  var parameters: [String: JSONValue] = [:]
  var customDocument: CustomProtocolDocument?
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("vibe-gateway: \(message)\n".utf8))
  exit(64)
}

func parse(_ arguments: [String]) -> Options {
  var options = Options()
  var iterator = arguments.makeIterator()
  func value(_ flag: String) -> String {
    guard let next = iterator.next() else { fail("\(flag) needs a value") }
    return next
  }
  while let argument = iterator.next() {
    switch argument {
    case "--base-url":
      options.baseURL = URL(string: value(argument))
    case "--protocol":
      let raw = value(argument)
      guard let parsed = EndpointWireProtocol(rawValue: raw) else {
        fail("unknown protocol \(raw); one of chatCompletions, responses, messages, custom")
      }
      options.wireProtocol = parsed
    case "--model":
      options.model = value(argument)
    case "--secret-env":
      options.secretVariable = value(argument)
    case "--auth-header":
      options.authentication = .header(name: value(argument))
    case "--no-auth":
      options.authentication = .none
    case "--port":
      guard let port = UInt16(value(argument)) else { fail("--port needs a number") }
      options.port = port
    case "--custom-document":
      let path = value(argument)
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
      }
      do {
        options.customDocument = try CustomProtocolDocument(parsing: text)
      } catch {
        fail("the custom protocol document: \(error)")
      }
    case "--parameters":
      guard case .object(let fields)? = try? JSONValue(parsing: value(argument)) else {
        fail("--parameters needs a JSON object")
      }
      options.parameters = fields
    default:
      fail("unknown argument \(argument)")
    }
  }
  return options
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard let baseURL = options.baseURL else { fail("--base-url is required") }
guard let model = options.model else { fail("--model is required") }
let secret = options.secretVariable.flatMap { ProcessInfo.processInfo.environment[$0] }
if options.secretVariable != nil, secret == nil { fail("the secret variable is not set") }

let routes = GatewayRouteTable()
let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
await routes.register(
  GatewayRoute(
    endpoint: EndpointConfiguration(
      baseURL: baseURL, wireProtocol: options.wireProtocol,
      authentication: options.authentication, defaultParameters: options.parameters,
      customProtocol: options.customDocument),
    secret: secret, model: model),
  token: token)

struct StandardErrorObserver: GatewayObserving {
  func retrying(
    token: String, attempt: Int, of maximum: Int, after delay: Duration, failure: EndpointFailure
  ) async {
    FileHandle.standardError.write(
      Data("retry \(attempt)/\(maximum) in \(delay): \(failure.kind.rawValue)\n".utf8))
  }

  func serverStep(token: String, step: CanonicalServerStep) async {
    FileHandle.standardError.write(Data("server step: \(step.name)\n".utf8))
  }
}

let transport = URLSessionEndpointTransport()
let gateway = Gateway(routes: routes, transport: transport, observer: StandardErrorObserver())
let server: GatewayHTTPServer
do {
  server = try GatewayHTTPServer(port: options.port, handler: gateway)
} catch {
  fail("cannot listen: \(error)")
}
let port = try await server.start()
print("ANTHROPIC_BASE_URL=http://127.0.0.1:\(port)/s/\(token) ANTHROPIC_AUTH_TOKEN=\(token)")
fflush(stdout)
while true { try await Task.sleep(for: .seconds(3_600)) }
