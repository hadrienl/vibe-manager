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
  }
}
