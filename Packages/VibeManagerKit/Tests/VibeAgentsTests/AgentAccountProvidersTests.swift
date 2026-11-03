import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("The extra accounts as agents")
struct AgentAccountProvidersTests {
  private let environment = ["HOME": "/Users/someone", "PATH": "/usr/bin"]
  private let installation = AgentInstallation(
    executablePath: "/usr/bin/true", version: AgentVersion(major: 3, minor: 0, patch: 0),
    source: .candidateDirectory, detectedAt: Date())

  private func base(pinned: [String: String]) -> CommandLineAgentProvider {
    let probe = SystemProcessProbe()
    return CommandLineAgentProvider(
      descriptor: ClaudeCodeAgentProvider.descriptor,
      specification: ClaudeCodeAgentProvider.specification,
      argumentBuilder: ClaudeCodeArgumentBuilder(),
      availabilityProbe: AgentAvailabilityProbe(
        descriptor: ClaudeCodeAgentProvider.descriptor,
        specification: ClaudeCodeAgentProvider.specification,
        locator: FileSystemExecutableLocator(environment: environment, probe: probe),
        probe: probe, environment: environment),
      environment: environment, pinnedEnvironment: pinned)
  }

  @Test("The account's folder wins over one the shell exports")
  func pinnedWinsOverShell() throws {
    let shell = ["CLAUDE_CONFIG_DIR": "/Users/someone/.from-zshrc"]
    let request = AgentLaunchRequest(workingDirectoryPath: "/tmp")
    let plain = try base(pinned: [:]).plan(
      for: request, installation: installation, shellEnvironment: shell)
    #expect(plain.environment["CLAUDE_CONFIG_DIR"] == "/Users/someone/.from-zshrc")
    let pinned = try base(pinned: ["CLAUDE_CONFIG_DIR": "/Users/someone/.two"]).plan(
      for: request, installation: installation, shellEnvironment: shell)
    #expect(pinned.environment["CLAUDE_CONFIG_DIR"] == "/Users/someone/.two")
  }

  @Test("An account is its CLI's provider, under its own name and identifier")
  func descriptors() throws {
    let claude = AgentAccount(name: "Perso", harness: .claudeCode, configurationDirectory: "~/.c2")
    let provider = try #require(
      AgentAccountProviders.make(claude, environment: environment) as? ClaudeCodeAgentProvider)
    #expect(provider.descriptor.id.rawValue == claude.providerID)
    #expect(provider.descriptor.id.isAccount)
    #expect(provider.descriptor.displayName == "Perso")
    #expect(provider.projectsDirectory.path == "/Users/someone/.c2/projects")
    let codex = AgentAccount(name: "C", harness: .codex, configurationDirectory: "~/.x2")
    #expect(AgentAccountProviders.make(codex, environment: environment) is CodexAgentProvider)
    let relative = AgentAccount(name: "R", harness: .codex, configurationDirectory: "x2")
    #expect(AgentAccountProviders.make(relative, environment: environment) == nil)
  }

  @Test("Its conversations are recorded under the account, read as its CLI's")
  func recording() {
    let account = AgentProviderID("account.1")
    let recording = ClaudeCodeAgentProvider.recording(of: account)
    #expect(recording.providerID == "account.1")
    #expect(recording.harnessID == "claude-code")
    #expect(ClaudeCodeAgentProvider.recording(of: ClaudeCodeAgentProvider.id).harnessID == nil)
  }

  @Test("A transcript is found in an account's folder, by the locator and the cache")
  func transcripts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-homes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = root.appendingPathComponent("account", isDirectory: true)
    let project = account.appendingPathComponent("projects/-work", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("abc.jsonl")
    try Data().write(to: file)

    let homes = AgentHomes()
    let locator = AgentTranscriptLocator(
      claudeProjects: root.appendingPathComponent("own/projects"),
      codexSessions: root.appendingPathComponent("own/sessions"), homes: homes)
    #expect(locator.claudeTranscripts(for: "abc").isEmpty)
    homes.replace(claudeHomes: [account], codexHomes: [])
    #expect(locator.claudeTranscripts(for: "abc").map(\.lastPathComponent) == ["abc.jsonl"])
    let cache = TranscriptLocationCache(locator: locator)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: nil)?.lastPathComponent == "abc.jsonl")
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: "/work") != nil)
  }

  @Test("The address is read from the CLI's status")
  func email() {
    #expect(
      ClaudeCodeAuthenticationStatus.account(in: #"{"loggedIn":true,"email":"a@b.c"}"#) == "a@b.c")
    #expect(ClaudeCodeAuthenticationStatus.account(in: #"{"loggedIn":false}"#) == nil)
  }

  @Test("The command to sign in says which folder")
  func signInCommand() {
    #expect(AgentHomeDirectory.shellQuoted("/a/.b-c") == "/a/.b-c")
    #expect(AgentHomeDirectory.shellQuoted("/a b") == "'/a b'")
  }
}
