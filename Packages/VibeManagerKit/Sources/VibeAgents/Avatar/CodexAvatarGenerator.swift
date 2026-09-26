import Foundation
import VibeApplication
import VibeProcess

/// `codex exec` drawing an avatar with its image generation tool (#41).
///
/// Ephemeral, outside any repository, without the user's configuration, hooks, MCP servers, apps,
/// plugins or web search: the description comes from the user, and nothing in the run needs more
/// than to draw and write one file. The sandbox lets it write in its own temporary folder only.
/// The image is read from that folder, as the file it was told to write, and nowhere else.
public struct CodexAvatarGenerator: AvatarGenerating {
  /// A sheet took 80 s in the spike of #41, an expression 106 s: five minutes leaves room.
  public static let timeout: Duration = .seconds(300)
  static let referenceFile = "reference.png"

  private let provider: any AgentProvider
  private let runner: any SummaryProcessRunning

  public init(
    provider: any AgentProvider, runner: any SummaryProcessRunning = BoundedSummaryProcessRunner()
  ) {
    self.provider = provider
    self.runner = runner
  }

  public func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    let run = OneShotAgentRun(
      provider: provider, runner: runner, folderPrefix: "VibeManager-avatar-",
      timeout: Self.timeout)
    do {
      return try await run.run { workspace, _ in
        var hasReference = false
        if let reference = request.reference {
          do {
            try reference.write(to: workspace.appendingPathComponent(Self.referenceFile))
            hasReference = true
          } catch {
            throw AvatarGenerationError.failed("no reference file")
          }
        }
        return OneShotAgentRun.Invocation(
          arguments: Self.arguments(withReference: hasReference), environment: [:],
          input: Data(request.prompt.utf8))
      } read: { result, workspace in
        guard !result.didTimeOut else { throw AvatarGenerationError.timedOut }
        guard result.exitCode == 0 else { throw Self.failure(of: result) }
        return try Self.image(in: workspace)
      }
    } catch let failure as OneShotAgentRun.Failure {
      switch failure {
      case .unavailable(let state): throw AvatarGenerationError.unavailable(Self.unavailability(state))
      case .noWorkspace: throw AvatarGenerationError.failed("no temporary folder")
      case .noLaunchPlan: throw AvatarGenerationError.failed("no launch plan")
      case .couldNotStart: throw AvatarGenerationError.failed("could not start")
      }
    }
  }

  /// The arguments of one run. The prompt goes on the standard input.
  static func arguments(withReference: Bool) -> [String] {
    var arguments = [
      "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
      "-s", "workspace-write",
      "--enable", "image_generation",
      "--disable", "hooks", "--disable", "apps", "--disable", "plugins",
      "-c", "mcp_servers={}", "-c", "tools.web_search=false",
    ]
    if withReference { arguments += ["-i", referenceFile] }
    arguments.append("-")
    return arguments
  }

  /// The file the agent was told to write: a plain file, not a link to one elsewhere, and not
  /// larger than any image is read.
  static func image(in workspace: URL) throws -> Data {
    let url = workspace.appendingPathComponent(AvatarPrompt.outputFileName)
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { throw AvatarGenerationError.noImage }
    guard let size = attributes[.size] as? Int, size > 0, size <= 25 * 1024 * 1024,
      let data = try? Data(contentsOf: url)
    else { throw AvatarGenerationError.rejected(.imageTooLarge) }
    return data
  }

  static func failure(of result: BoundedProcessResult) -> AvatarGenerationError {
    switch CommandLineSummarizer.failure(of: result) {
    case .unavailable(.outdated): return .unavailable(.outdated)
    case .unavailable(.signedOut): return .unavailable(.signedOut)
    case .unavailable: return .unavailable(.missing)
    case .failed(let reason): return .failed(reason)
    }
  }

  static func unavailability(_ state: AgentAvailabilityState) -> AvatarGenerationUnavailability {
    switch state {
    case .unauthenticated: return .signedOut
    case .outdated: return .outdated
    default: return .missing
    }
  }
}

extension CodexAgentProvider: AvatarGeneratingProviding {
  public func avatarGenerator() -> any AvatarGenerating {
    CodexAvatarGenerator(provider: self)
  }
}
