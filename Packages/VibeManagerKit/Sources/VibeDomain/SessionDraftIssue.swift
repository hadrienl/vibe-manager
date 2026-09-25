import Foundation

public enum SessionDraftField: String, Hashable, Sendable, CaseIterable {
  case name
  case initialPrompt
  case agent
  case model
  case workingDirectory
  case appearance
  /// One of the fields a template adds to the form; the issue names which in `fieldKey`.
  case templateField
}

/// One reason a draft cannot be created, and the way out of it.
///
/// Shaped like `TerminalError` and `AgentLaunchError` — a sentence and a remedy — so a validation
/// problem, a launch refusal and a terminal failure all render through one view.
public struct SessionDraftIssue: Hashable, Sendable, Identifiable, LocalizedError {
  public let field: SessionDraftField
  public let message: String
  public let remedy: String
  /// The template field this is about, when `field` is `.templateField`.
  public let fieldKey: String?

  public init(field: SessionDraftField, message: String, remedy: String, fieldKey: String? = nil) {
    self.field = field
    self.message = message
    self.remedy = remedy
    self.fieldKey = fieldKey
  }

  public var id: String {
    "\(field.rawValue)|\(fieldKey ?? "")|\(message)"
  }

  public var errorDescription: String? {
    message
  }

  public var recoverySuggestion: String? {
    remedy
  }

  public static let nameMissing = SessionDraftIssue(
    field: .name,
    message: String(localized: "A name is required.", bundle: .module),
    remedy: String(
      localized: "Describe the task in a few words — it labels the session in the sidebar.",
      bundle: .module)
  )

  public static let workingDirectoryMissing = SessionDraftIssue(
    field: .workingDirectory,
    message: String(localized: "No working folder was chosen.", bundle: .module),
    remedy: String(localized: "Choose the folder the agent should work in.", bundle: .module)
  )

  public static let workingDirectoryNotAbsolute = SessionDraftIssue(
    field: .workingDirectory,
    message: String(localized: "The working folder must be an absolute path.", bundle: .module),
    remedy: String(
      localized: "Choose the folder again, or type a path starting with / or ~.", bundle: .module)
  )

  public static let workingDirectoryNotFound = SessionDraftIssue(
    field: .workingDirectory,
    message: String(localized: "This folder no longer exists.", bundle: .module),
    remedy: String(localized: "Choose one that is still there and readable.", bundle: .module)
  )

  public static let workingDirectoryNotADirectory = SessionDraftIssue(
    field: .workingDirectory,
    message: String(localized: "This path is a file, not a folder.", bundle: .module),
    remedy: String(localized: "Choose the folder that contains it.", bundle: .module)
  )

  public static let workingDirectoryUnreadable = SessionDraftIssue(
    field: .workingDirectory,
    message: String(localized: "This folder cannot be read.", bundle: .module),
    remedy: String(localized: "Grant access to the folder, or choose another one.", bundle: .module)
  )

  public static let agentMissing = SessionDraftIssue(
    field: .agent,
    message: String(localized: "No coding agent is selected.", bundle: .module),
    remedy: String(localized: "Pick one of the agents detected on this Mac.", bundle: .module)
  )

  public static func agentUnknown(_ id: String) -> SessionDraftIssue {
    SessionDraftIssue(
      field: .agent,
      message: String(
        localized: "The agent \(id) is not registered any more.", bundle: .module,
        comment: "An agent's identifier, as stored with the session: claude-code, codex."),
      remedy: String(localized: "Pick one of the agents listed above.", bundle: .module)
    )
  }

  public static func agentUnavailable(name: String, summary: String, remedy: String)
    -> SessionDraftIssue
  {
    SessionDraftIssue(
      field: .agent,
      message: String(
        localized: "\(name) cannot be launched. \(summary)", bundle: .module,
        comment: "An agent's name, then the sentence that says why it cannot be launched."),
      remedy: remedy
    )
  }

  public static func modelUnknown(_ id: String) -> SessionDraftIssue {
    SessionDraftIssue(
      field: .model,
      message: String(
        localized: "The model \(id) is not offered by this agent.", bundle: .module,
        comment: "A model's identifier, as the agent's command line takes it."),
      remedy: String(localized: "Go back to the default model of the agent.", bundle: .module)
    )
  }

  public static func promptRejected(message: String, remedy: String) -> SessionDraftIssue {
    SessionDraftIssue(field: .initialPrompt, message: message, remedy: remedy)
  }

  public static func templateFieldMissing(_ field: PromptTemplateField) -> SessionDraftIssue {
    SessionDraftIssue(
      field: .templateField,
      message: String(
        localized: "\(field.label) is required.", bundle: .module,
        comment: "The label of a field the chosen prompt template adds to the form."),
      remedy: String(localized: "Fill it in, or pick another template.", bundle: .module),
      fieldKey: field.name
    )
  }

  public static let promptControlCharacters = SessionDraftIssue(
    field: .initialPrompt,
    message: String(
      localized:
        "The prompt contains invisible control characters the agent would not read as text.",
      bundle: .module),
    remedy: String(
      localized: "Remove them — they usually come with text pasted from a coloured terminal.",
      bundle: .module)
  )

  public static let appearanceInvalid = SessionDraftIssue(
    field: .appearance,
    message: String(localized: "This session identity cannot be stored.", bundle: .module),
    remedy: String(localized: "Pick a symbol and a colour from the ones offered.", bundle: .module)
  )
}
