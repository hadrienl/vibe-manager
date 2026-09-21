import Foundation
import VibeApplication

/// Reads the sign in state out of `claude auth status --json`, and nothing else.
///
/// That answer also carries the account's email address, organization and subscription type.
/// None of them is decoded: the application has no business knowing who the user is, and a
/// field that is never read cannot leak into a log or an exported diagnostic.
public enum ClaudeCodeAuthenticationStatus {
  /// `nil` means unknown, which never blocks a launch: the CLI asks for itself, in the
  /// terminal, where the user can answer.
  public static func isSignedIn(in result: ProbeResult) -> Bool? {
    let output = result.standardOutput.isEmpty ? result.combinedOutput : result.standardOutput
    guard let data = output.data(using: .utf8), !data.isEmpty else {
      return result.exitCode == 0 ? nil : false
    }
    guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
      // An unreadable answer says nothing about the account, only about the format.
      return result.exitCode == 0 ? nil : false
    }
    return status.loggedIn
  }

  private struct Status: Decodable {
    let loggedIn: Bool
  }
}
