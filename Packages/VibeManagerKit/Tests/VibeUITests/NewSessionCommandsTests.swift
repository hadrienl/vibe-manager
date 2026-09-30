import Foundation
import Testing
import VibeApplication
import VibeConversationUI
import VibeDomain

@testable import VibeUI

/// An agent that lists two commands, and says for which folder it was asked.
private struct ListingProvider: AgentProvider, AgentCommandListing {
  let descriptor = AgentDescriptor(
    id: AgentProviderID("claude-code"), displayName: "Claude Code",
    capabilities: AgentCapabilities(
      supportsModelSelection: false, supportsInitialPrompt: true, supportsResume: false))
  let folders: FolderLog

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available, installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "Ready.", probedAt: Date(timeIntervalSince1970: 0), remediations: []))
  }
  func models() async -> [AgentModel] { [] }
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw AgentLaunchError.invalidWorkingDirectory
  }

  func commands(inWorkingDirectory workingDirectoryPath: String, refresh: Bool) async throws
    -> AgentCommandList
  {
    await folders.append(workingDirectoryPath)
    return AgentCommandList(commands: [
      AgentCommand(
        name: "prisme-ai:debug-events", invocation: "/prisme-ai:debug-events",
        description: "Trace.", argumentHint: "[correlationId]", kind: .skill,
        origin: .plugin("prisme-ai")),
      AgentCommand(
        name: "compact", invocation: "/compact", description: "Free up context.",
        kind: .command, origin: .builtin),
    ])
  }
}

private actor FolderLog {
  private(set) var folders: [String] = []
  func append(_ folder: String) { folders.append(folder) }
}

private struct Registry: AgentProviderResolving {
  let provider: ListingProvider
  func descriptors() async -> [AgentDescriptor] { [provider.descriptor] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    id == provider.descriptor.id ? provider : nil
  }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    [provider.descriptor.id: await provider.availability(forceRefresh: forceRefresh)]
  }
}

@MainActor
@Suite("The list of skills and commands in a new session's prompt (#219)", .timeLimit(.minutes(1)))
struct NewSessionCommandsTests {
  private func model() -> (NewSessionModel, FolderLog) {
    let log = FolderLog()
    let registry = Registry(provider: ListingProvider(folders: log))
    let model = NewSessionModel(
      create: CreateSession(repository: WorkspaceRepository(sessions: []), agents: registry),
      registry: registry)
    return (model, log)
  }

  private func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled { await Task.yield() }
  }

  @Test("It lists what the chosen agent accepts in the chosen folder, once `/` is typed")
  func listing() async {
    let (model, log) = model()
    model.draft.providerID = "claude-code"
    model.draft.workingDirectoryPath = "/tmp/project"
    // A folder chosen reads nothing: the list is read when it opens.
    for _ in 0..<20 { await Task.yield() }
    #expect(await log.folders.isEmpty)
    model.draft.initialPrompt = "/deb"
    await until { model.commands.isShowing }
    #expect(model.commands.suggestions?.map(\.command.name) == ["prisme-ai:debug-events"])
    #expect(await log.folders == ["/tmp/project"])
  }

  @Test("Inserting puts the command in the prompt, with its hint; the prompt then sends it")
  func inserting() async {
    let (model, _) = model()
    model.draft.providerID = "claude-code"
    model.draft.workingDirectoryPath = "/tmp/project"
    model.draft.initialPrompt = "/"
    await until { model.commands.isShowing }
    model.insertCommand(model.commands.selectedCommand!)
    #expect(model.draft.initialPrompt == "/prisme-ai:debug-events ")
    #expect(!model.commands.isShowing)
    #expect(model.commands.pendingArgumentHint == "[correlationId]")
    #expect(model.commands.insertedInvocation == "/prisme-ai:debug-events")
  }

  @Test("Without an agent or a folder, `/` is text")
  func nothingChosen() async {
    let (model, log) = model()
    model.draft.providerID = "claude-code"
    model.draft.initialPrompt = "/"
    for _ in 0..<20 { await Task.yield() }
    #expect(!model.commands.isShowing)
    #expect(await log.folders.isEmpty)
  }
}
