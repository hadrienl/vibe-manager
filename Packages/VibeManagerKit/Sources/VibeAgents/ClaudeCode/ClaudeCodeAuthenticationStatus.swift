import Foundation
import VibeApplication

public enum ClaudeCodeAuthenticationStatus {
  public static func isSignedIn(in result: ProbeResult) -> Bool? {
    let output = result.standardOutput.isEmpty ? result.combinedOutput : result.standardOutput
    if let status = decodeStatus(in: output) {
      return status.loggedIn
    }
    return result.exitCode == 0 ? nil : false
  }

  /// How the account `auth status --json` describes is signed in again (#419). `auth login`
  /// without an option signs a Claude subscription in; a Console account — a key the CLI's
  /// `/login` manages — is signed in from the terminal, where `/login` asks which. A key, a
  /// token or a provider set in the environment is not the CLI's to change.
  public static func signInRoute(in output: String) -> AgentSignInRoute {
    guard let status = decodeStatus(in: output) else { return .browser }
    switch status.authMethod {
    case nil, "claude.ai", "none": return .browser
    case "api_key" where status.apiKeySource == "/login managed key": return .terminal
    case "api_key", "api_key_helper", "oauth_token", "third_party": return .elsewhere
    default: return .terminal
    }
  }

  /// The account `auth status --json` describes, as the user tells it from another (#478): one
  /// address can sign in to several organizations, chosen on the sign-in page. A personal one has
  /// no name of its own, only one made from the address: its plan says it better.
  public static func account(in output: String) -> String? {
    guard let status = decodeStatus(in: output), let email = status.email, !email.isEmpty else {
      return nil
    }
    let organization =
      if let name = status.orgName, !name.isEmpty, !name.localizedCaseInsensitiveContains(email) {
        name
      } else {
        status.subscriptionType?.capitalized
      }
    guard let organization, !organization.isEmpty else { return email }
    return "\(email) · \(organization)"
  }

  /// The answer as JSON, wherever it sits in the stream.
  ///
  /// Anything else the run put on the way — a Node deprecation warning, a proxy or certificate
  /// notice, an update banner — is noise around the answer, not part of it, so the whole stream
  /// failing to decode says nothing on its own. The object is looked for on its own first, then
  /// line by line, then as the span between the outermost braces.
  private static func decodeStatus(in output: String) -> Status? {
    if let status = decode(output) { return status }
    for line in output.split(whereSeparator: \.isNewline) {
      if let status = decode(String(line)) { return status }
    }
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
      start < end
    else {
      return nil
    }
    return decode(String(output[start...end]))
  }

  private static func decode(_ text: String) -> Status? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8), !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
  }

  private struct Status: Decodable {
    let loggedIn: Bool
    let authMethod: String?
    let apiKeySource: String?
    let email: String?
    let orgName: String?
    let subscriptionType: String?
  }
}
