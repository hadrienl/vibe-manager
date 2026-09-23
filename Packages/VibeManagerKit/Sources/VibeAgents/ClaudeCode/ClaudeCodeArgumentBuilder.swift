import Foundation
import VibeApplication

/// Builds the `claude` command line for one launch.
///
/// Claude Code accepts the session identifier it is given, so a fresh launch carries one that
/// Vibe Manager generated: nothing has to be discovered afterwards. Resuming passes that same
/// identifier back, and never alongside `--session-id`, which the CLI refuses.
public struct ClaudeCodeArgumentBuilder: CommandLineAgentArgumentBuilder {
  public static let sessionIdentifierOption = "--session-id"
  public static let resumeOption = "--resume"

  private let makeIdentifier: @Sendable () -> UUID

  public init(makeIdentifier: @escaping @Sendable () -> UUID = { UUID() }) {
    self.makeIdentifier = makeIdentifier
  }

  public func arguments(
    for request: AgentLaunchRequest,
    promptDelivery: PromptDelivery,
    descriptor: AgentDescriptor
  ) throws -> [String] {
    var arguments: [String] = []

    switch request.resume {
    case .identifier(let identifier):
      arguments.append(
        contentsOf: [Self.resumeOption, try Self.validatedResumeIdentifier(identifier)])
    case .none:
      // The conversation is named before it exists, so it stays resumable even if the process
      // dies in its first second.
      arguments.append(
        contentsOf: [Self.sessionIdentifierOption, makeIdentifier().uuidString.lowercased()])
    }

    if let modelID = request.modelID {
      arguments.append(contentsOf: ["--model", try Self.validatedModelID(modelID)])
    }

    switch promptDelivery {
    case .none:
      break
    case .argument:
      // Without `--`, a prompt starting with a dash is read as an option and the CLI refuses
      // to start at all.
      arguments.append(contentsOf: ["--", request.initialPrompt ?? ""])
    case .standardInput(let prompt):
      // In a pseudo terminal the standard input is the keyboard: writing there types into the
      // composer, and the first newline submits a half written message.
      throw AgentLaunchError.promptTooLarge(
        byteCount: prompt.utf8.count,
        limit: AgentPromptLimits.argumentByteLimit
      )
    }

    return arguments
  }

  /// The CLI refuses anything but a UUID, so the refusal happens before a process is started.
  static func validatedResumeIdentifier(_ identifier: String) throws -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: trimmed) else {
      throw AgentLaunchError.missingResumeIdentifier
    }
    return uuid.uuidString.lowercased()
  }

  /// Shape only: the catalog lives with the account and changes faster than this application.
  static func validatedModelID(_ modelID: String) throws -> String {
    guard AgentArgumentToken.isWellFormedIdentifier(modelID) else {
      throw AgentLaunchError.unsupportedModel(modelID)
    }
    return modelID
  }

  /// The identifier a plan assigns, read back from the command line it produced.
  public static func assignedSessionIdentifier(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: sessionIdentifierOption) else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else { return nil }
    return UUID(uuidString: arguments[valueIndex]).map { $0.uuidString.lowercased() }
  }
}
