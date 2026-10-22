import Foundation

/// An agent whose CLI signs its account in again by itself, in the browser (#410): Claude Code's
/// `claude auth login`.
public protocol AgentSigningIn: Sendable {
  /// Runs the CLI's sign-in until it ends, then asks the CLI again whether it is signed in.
  /// Cancelling the task stops it.
  func signIn() async -> AgentSignInOutcome
  /// How the account the CLI uses now is signed in again (#419).
  func signInRoute() async -> AgentSignInRoute
}

/// How an agent's account is signed in again (#419).
public enum AgentSignInRoute: Equatable, Sendable {
  /// By `signIn()`, in the browser — or by the CLI's own command, in the terminal.
  case browser
  /// By the CLI's own command, in the terminal, only: an account `signIn()` would not sign in.
  case terminal
  /// Neither: a key or a provider set outside the CLI, which signing in again does not change.
  case elsewhere
}

public enum AgentSignInOutcome: Equatable, Sendable {
  case signedIn
  /// The sign-in ended, and the CLI is still not signed in: what it said, when it said anything.
  case notSignedIn(detail: String?)
  case cancelled
}

extension ConversationEntry {
  /// The prompt a turn that failed on the sign-in was given (#410): the last of the user's, with
  /// nothing of the agent's after it — the error aside. `nil` when the agent answered it, or when
  /// there is none.
  public static func promptFailedOnSignIn(in entries: [ConversationEntry]) -> String? {
    guard let index = entries.lastIndex(where: \.isUserPrompt),
      case .userPrompt(let text, _) = entries[index].content,
      entries[(index + 1)...].allSatisfy({ entry in
        if case .notice = entry.content { return true }
        return false
      })
    else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : text
  }

  /// Whether the turn that failed on the sign-in had begun (#419): the agent had answered the
  /// last of the user's prompts in part — the error aside — and is to go on with it.
  public static func turnFailedOnSignInMidway(in entries: [ConversationEntry]) -> Bool {
    guard let index = entries.lastIndex(where: \.isUserPrompt) else { return false }
    return entries[(index + 1)...].contains { entry in
      if case .notice = entry.content { return false }
      return true
    }
  }
}
