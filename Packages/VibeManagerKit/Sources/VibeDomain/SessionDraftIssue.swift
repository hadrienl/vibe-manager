import Foundation

public enum SessionDraftField: String, Hashable, Sendable, CaseIterable {
  case name
  case initialPrompt
  case agent
  case model
  case workingDirectory
}

/// One reason a draft cannot be created, and the way out of it.
///
/// Shaped like `TerminalError` and `AgentLaunchError` — a sentence and a remedy — so a validation
/// problem, a launch refusal and a terminal failure all render through one view.
public struct SessionDraftIssue: Hashable, Sendable, Identifiable, LocalizedError {
  public let field: SessionDraftField
  public let message: String
  public let remedy: String

  public init(field: SessionDraftField, message: String, remedy: String) {
    self.field = field
    self.message = message
    self.remedy = remedy
  }

  public var id: String {
    "\(field.rawValue)|\(message)"
  }

  public var errorDescription: String? {
    message
  }

  public var recoverySuggestion: String? {
    remedy
  }

  public static let nameMissing = SessionDraftIssue(
    field: .name,
    message: "A name is required.",
    remedy: "Describe the task in a few words — it labels the session in the sidebar."
  )

  public static let workingDirectoryMissing = SessionDraftIssue(
    field: .workingDirectory,
    message: "No working folder was chosen.",
    remedy: "Choose the folder the agent should work in."
  )

  public static let workingDirectoryNotAbsolute = SessionDraftIssue(
    field: .workingDirectory,
    message: "The working folder must be an absolute path.",
    remedy: "Choose the folder again, or type a path starting with / or ~."
  )

  public static let workingDirectoryNotFound = SessionDraftIssue(
    field: .workingDirectory,
    message: "This folder no longer exists.",
    remedy: "Choose one that is still there and readable."
  )

  public static let workingDirectoryNotADirectory = SessionDraftIssue(
    field: .workingDirectory,
    message: "This path is a file, not a folder.",
    remedy: "Choose the folder that contains it."
  )

  public static let workingDirectoryUnreadable = SessionDraftIssue(
    field: .workingDirectory,
    message: "This folder cannot be read.",
    remedy: "Grant access to the folder, or choose another one."
  )

  public static let agentMissing = SessionDraftIssue(
    field: .agent,
    message: "No coding agent is selected.",
    remedy: "Pick one of the agents detected on this Mac."
  )

  public static func agentUnknown(_ id: String) -> SessionDraftIssue {
    SessionDraftIssue(
      field: .agent,
      message: "The agent \(id) is not registered any more.",
      remedy: "Pick one of the agents listed above."
    )
  }

  public static func agentUnavailable(name: String, summary: String, remedy: String)
    -> SessionDraftIssue
  {
    SessionDraftIssue(
      field: .agent,
      message: "\(name) cannot be launched. \(summary)",
      remedy: remedy
    )
  }

  public static func modelUnknown(_ id: String) -> SessionDraftIssue {
    SessionDraftIssue(
      field: .model,
      message: "The model \(id) is not offered by this agent.",
      remedy: "Go back to the default model of the agent."
    )
  }

  public static func promptRejected(message: String, remedy: String) -> SessionDraftIssue {
    SessionDraftIssue(field: .initialPrompt, message: message, remedy: remedy)
  }

  public static let appearanceInvalid = SessionDraftIssue(
    field: .name,
    message: "This session identity cannot be stored.",
    remedy: "Pick a symbol and a colour from the ones offered."
  )
}
