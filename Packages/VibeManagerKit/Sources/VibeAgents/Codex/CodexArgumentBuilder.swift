import Foundation
import VibeApplication

/// Turns a launch request into the `argv` of the interactive Codex terminal interface.
///
/// Pure and total: the same request always yields the same array, so the generated commands
/// are covered by golden tests without ever running `codex`.
public struct CodexArgumentBuilder: CommandLineAgentArgumentBuilder {
  public init() {}

  public func arguments(
    for request: AgentLaunchRequest,
    promptDelivery: PromptDelivery,
    descriptor: AgentDescriptor
  ) throws -> [String] {
    var arguments: [String] = []
    // Everything that is not an option goes after `--`, so a prompt or a session name
    // starting with `-` cannot be read as a flag by the CLI's parser.
    var positionals: [String] = []

    if case .identifier(let identifier) = request.resume {
      // The subcommand comes first: its options are parsed after it, not before.
      arguments.append("resume")
      positionals.append(try Self.validatedResumeIdentifier(identifier))
    }

    if let modelID = request.modelID {
      arguments.append(contentsOf: ["-m", try Self.validatedModelID(modelID)])
    }

    // Passed explicitly even though the terminal already starts the process there: `codex`
    // derives its workspace root and filters resumable sessions from this directory.
    arguments.append(contentsOf: ["-C", request.workingDirectoryPath])

    switch promptDelivery {
    case .none:
      break
    case .argument:
      positionals.append(request.initialPrompt ?? "")
    case .standardInput(let prompt):
      // In a pseudo terminal the standard input *is* the keyboard: writing a prompt there
      // types it into the composer, and its first newline submits a half written message.
      throw AgentLaunchError.promptTooLarge(
        byteCount: prompt.utf8.count,
        limit: AgentPromptLimits.argumentByteLimit
      )
    }

    if !positionals.isEmpty {
      arguments.append("--")
      arguments.append(contentsOf: positionals)
    }
    return arguments
  }

  /// Only the shape of a slug is checked. Membership of a catalog is not: see
  /// `CodexAgentProvider.models()`.
  static func validatedModelID(_ modelID: String) throws -> String {
    guard isWellFormed(modelID), !modelID.contains("/") else {
      throw AgentLaunchError.unsupportedModel(modelID)
    }
    return modelID
  }

  /// A rollout identifier or a session name, never a path fragment and never a flag.
  static func validatedResumeIdentifier(_ identifier: String) throws -> String {
    guard isWellFormed(identifier), !identifier.contains("/") else {
      throw AgentLaunchError.missingResumeIdentifier
    }
    return identifier
  }

  private static func isWellFormed(_ value: String) -> Bool {
    AgentArgumentToken.isWellFormed(value)
  }
}
