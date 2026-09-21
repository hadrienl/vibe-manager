import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Resolving the agent of a stored session")
struct ResolveSessionAgentTests {
  private func session(providerID: String?) -> WorkSession {
    WorkSession(
      name: "Session",
      agent: providerID.map { SessionAgentConfiguration(providerID: $0, modelID: "fast") }
    )
  }

  @Test("A session without agent is simply unassigned")
  func unassignedSession() async {
    let resolution = await ResolveSessionAgent(registry: StubRegistry())(
      for: session(providerID: nil)
    )

    #expect(resolution == .unassigned)
    #expect(!resolution.isResumable)
  }

  @Test("A provider that disappeared makes the session not resumable, not unreadable")
  func unknownProvider() async {
    let resolution = await ResolveSessionAgent(registry: StubRegistry())(
      for: session(providerID: "retired-agent")
    )

    #expect(resolution == .unknownProvider("retired-agent"))
  }

  @Test("An installed but unusable provider surfaces its diagnostic")
  func unavailableProvider() async {
    let registry = StubRegistry(providers: [StubProvider(id: "claude", state: .notFound)])

    let resolution = await ResolveSessionAgent(registry: registry)(
      for: session(providerID: "claude")
    )

    guard case .unavailable(let diagnostic) = resolution else {
      Issue.record("Expected an unavailable resolution, got \(resolution)")
      return
    }
    #expect(diagnostic.state == .notFound)
    #expect(!diagnostic.remediations.isEmpty)
  }

  @Test("An available provider makes the session resumable")
  func readyProvider() async {
    let registry = StubRegistry(providers: [StubProvider(id: "claude", state: .available)])

    let resolution = await ResolveSessionAgent(registry: registry)(
      for: session(providerID: "claude")
    )

    #expect(resolution.isResumable)
  }
}

private struct StubProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState

  init(id: String, state: AgentAvailabilityState) {
    descriptor = AgentDescriptor(id: AgentProviderID(id), displayName: id)
    self.state = state
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: state,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: state,
        summary: "stub",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: [.retryDetection]
      )
    )
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw AgentLaunchError.unavailable(state)
  }
}

private struct StubRegistry: AgentProviderResolving {
  var providers: [StubProvider] = []

  func descriptors() async -> [AgentDescriptor] {
    providers.map(\.descriptor)
  }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    var result: [AgentProviderID: AgentAvailability] = [:]
    for provider in providers {
      result[provider.descriptor.id] = await provider.availability(forceRefresh: forceRefresh)
    }
    return result
  }
}
