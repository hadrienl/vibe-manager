import Foundation
import VibeApplication
import VibeDomain

/// The extra accounts as agents (#478): the very providers of Claude Code and Codex, under another
/// identifier and name, with the variable that gives the CLI its folder. Everything built on the
/// provider — hooks, tools, summaries, sign-in — follows, on the session's own account.
public enum AgentAccountProviders {
  public static func make(
    _ account: AgentAccount,
    environment: [String: String],
    diagnostics: any DiagnosticLog = NullDiagnosticLog(),
    shellEnvironment: (any ShellEnvironmentSource)? = nil,
    transcriptLocations: TranscriptLocationCache = TranscriptLocationCache()
  ) -> (any AgentProvider)? {
    let home = AgentHomeDirectory.home(in: environment)
    guard
      let directory = AgentAccount.resolvedDirectory(account.configurationDirectory, home: home)
    else { return nil }
    switch account.harness {
    case .claudeCode:
      var variables = environment
      variables[ClaudeCodeHome.overrideKey] = directory
      return ClaudeCodeAgentProvider.make(
        environment: variables, diagnostics: diagnostics, shellEnvironment: shellEnvironment,
        transcriptLocations: transcriptLocations,
        account: descriptor(of: account, like: ClaudeCodeAgentProvider.descriptor))
    case .codex:
      var variables = environment
      variables[CodexHome.overrideKey] = directory
      return CodexAgentProvider.make(
        environment: variables, diagnostics: diagnostics, shellEnvironment: shellEnvironment,
        transcriptLocations: transcriptLocations,
        account: descriptor(of: account, like: CodexAgentProvider.descriptor))
    }
  }

  /// The folders that hold the accounts' conversations, for the readers of transcripts.
  public static func updateHomes(
    _ homes: AgentHomes, for accounts: [AgentAccount], environment: [String: String]
  ) {
    let home = AgentHomeDirectory.home(in: environment)
    func folders(_ harness: EndpointHarness) -> [URL] {
      accounts.filter { $0.harness == harness }.compactMap {
        AgentAccount.resolvedDirectory($0.configurationDirectory, home: home).map {
          URL(fileURLWithPath: $0, isDirectory: true)
        }
      }
    }
    homes.replace(claudeHomes: folders(.claudeCode), codexHomes: folders(.codex))
  }

  private static func descriptor(of account: AgentAccount, like agent: AgentDescriptor)
    -> AgentDescriptor
  {
    AgentDescriptor(
      id: AgentProviderID(account.providerID), displayName: account.name,
      symbolName: agent.symbolName, minimumVersion: agent.minimumVersion,
      capabilities: agent.capabilities)
  }
}
