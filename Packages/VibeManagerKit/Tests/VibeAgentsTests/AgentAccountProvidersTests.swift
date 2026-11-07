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
    #expect(locator.claudeTranscripts(for: "abc", providerID: "account.1").isEmpty)
    homes.replace(claudeHomes: ["account.1": account], codexHomes: [:])
    #expect(
      locator.claudeTranscripts(for: "abc", providerID: "account.1").map(\.lastPathComponent)
        == ["abc.jsonl"])
    let cache = TranscriptLocationCache(locator: locator)
    #expect(
      cache.claudeTranscript(for: "abc", providerID: "account.1", workingDirectory: nil)?
        .lastPathComponent == "abc.jsonl")
    #expect(
      cache.claudeTranscript(for: "abc", providerID: "account.1", workingDirectory: "/work") != nil)
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

  /// `cp -R ~/.claude ~/.claude-2`: every file of the copy is newer than its original.
  @Test("A folder copied to start an account does not count a conversation twice")
  func copiedHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func transcript(in home: String, at date: Date) throws -> URL {
      let folder = root.appendingPathComponent(home).appendingPathComponent("projects/p")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("abc.jsonl")
      try Data().write(to: file)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
      return file
    }
    let original = try transcript(in: "one", at: Date(timeIntervalSince1970: 1_000))
    let copy = try transcript(in: "two", at: Date(timeIntervalSince1970: 2_000))
    let homes = AgentHomes()
    homes.replace(claudeHomes: ["account.2": root.appendingPathComponent("two")], codexHomes: [:])
    let locator = AgentTranscriptLocator(
      claudeProjects: root.appendingPathComponent("one/projects"), homes: homes)
    func found(by providerID: String) -> [String] {
      locator.claudeTranscripts(for: "abc", providerID: providerID).map {
        $0.resolvingSymlinksInPath().path
      }
    }
    // The agent's conversation is its own folder's, the copy's however newer; an endpoint's too.
    #expect(found(by: "claude-code") == [original.resolvingSymlinksInPath().path])
    #expect(found(by: "endpoint.1") == [original.resolvingSymlinksInPath().path])
    #expect(found(by: "account.2") == [copy.resolvingSymlinksInPath().path])
    // An account removed: wherever it is, once — the folder written last.
    #expect(found(by: "account.gone") == [copy.resolvingSymlinksInPath().path])
    let cache = TranscriptLocationCache(locator: locator)
    #expect(
      cache.claudeTranscript(for: "abc", providerID: "claude-code", workingDirectory: nil)?
        .resolvingSymlinksInPath().path == original.resolvingSymlinksInPath().path)
  }

  @Test("A Codex folder copied to start an account does not count a rollout twice")
  func copiedCodexHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: day)
    func rollout(in home: String, at date: Date) throws -> URL {
      let folder = root.appendingPathComponent(home).appendingPathComponent(
        String(
          format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("rollout-x-xyz.jsonl")
      try Data().write(to: file)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
      return file
    }
    let original = try rollout(in: "one", at: Date(timeIntervalSince1970: 1_000))
    let copy = try rollout(in: "two", at: Date(timeIntervalSince1970: 2_000))
    let homes = AgentHomes()
    homes.replace(claudeHomes: [:], codexHomes: ["account.2": root.appendingPathComponent("two")])
    let locator = AgentTranscriptLocator(
      codexSessions: root.appendingPathComponent("one/sessions"), homes: homes)
    func found(by providerID: String) -> [String] {
      locator.codexRollouts(for: "xyz", providerID: providerID, since: day, until: day).map {
        $0.resolvingSymlinksInPath().path
      }
    }
    #expect(found(by: "codex") == [original.resolvingSymlinksInPath().path])
    #expect(found(by: "account.2") == [copy.resolvingSymlinksInPath().path])
    #expect(found(by: "account.gone") == [copy.resolvingSymlinksInPath().path])
  }
}
