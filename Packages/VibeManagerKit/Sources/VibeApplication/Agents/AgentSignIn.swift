import Foundation

/// An agent whose CLI signs its account in again by itself, in the browser (#410): Claude Code's
/// `claude auth login`.
public protocol AgentSigningIn: Sendable {
  /// Runs the CLI's sign-in until it ends, then asks the CLI again whether it is signed in.
  /// Cancelling the task stops it.
  func signIn() async -> AgentSignInOutcome
  /// How the account the CLI uses now is signed in again (#419).
  func signInRoute() async -> AgentSignInRoute
  /// The account the CLI uses (#478), to notice a sign-in to another one. `nil` when the CLI does
  /// not say.
  func signedInAccount() async -> AgentSignedInAccount?
  /// Whether a conversation stopped on its sign-in offers it. Otherwise only the settings do.
  var signsInFromConversations: Bool { get }
}

extension AgentSigningIn {
  public func signedInAccount() async -> AgentSignedInAccount? { nil }
  public var signsInFromConversations: Bool { true }
}

/// The account a CLI is signed in to (#478). One address can sign in to several organizations,
/// and an organization's name and plan can change: only the address and the identifier tell one
/// account from another, the label only shows it.
public struct AgentSignedInAccount: Equatable, Codable, Sendable, ExpressibleByStringLiteral {
  public var label: String
  public var email: String
  public var organizationID: String?

  public init(label: String, email: String, organizationID: String? = nil) {
    self.label = label
    self.email = email
    self.organizationID = organizationID
  }

  public init(stringLiteral email: String) {
    self.init(label: email, email: email)
  }

  /// An identifier the CLI did not give says nothing: an expired sign-in may well leave it out.
  public func isSame(as other: AgentSignedInAccount) -> Bool {
    guard email.caseInsensitiveCompare(other.email) == .orderedSame else { return false }
    guard let organizationID, let theirs = other.organizationID else { return true }
    return organizationID == theirs
  }
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
