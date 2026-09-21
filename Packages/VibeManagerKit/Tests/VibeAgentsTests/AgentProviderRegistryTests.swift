import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Provider registry")
struct AgentProviderRegistryTests {
  @Test("Providers keep their registration order")
  func keepsRegistrationOrder() async {
    let registry = AgentProviderRegistry(providers: [
      FakeProvider(id: "codex"),
      FakeProvider(id: "claude"),
      FakeProvider(id: "mock"),
    ])

    #expect(await registry.descriptors().map(\.id.rawValue) == ["codex", "claude", "mock"])
  }

  @Test("A duplicate identifier is registered once")
  func ignoresDuplicateIdentifiers() async {
    let registry = AgentProviderRegistry(providers: [
      FakeProvider(id: "claude"),
      FakeProvider(id: "claude"),
    ])

    #expect(await registry.descriptors().count == 1)
  }

  @Test("An unknown identifier resolves to nil instead of failing")
  func unknownIdentifierResolvesToNil() async {
    let registry = AgentProviderRegistry(providers: [FakeProvider(id: "claude")])

    #expect(await registry.provider(id: AgentProviderID("ghost")) == nil)
  }

  @Test("Availabilities are aggregated even when a provider is unavailable")
  func aggregatesMixedAvailabilities() async {
    let registry = AgentProviderRegistry(providers: [
      FakeProvider(id: "claude", state: .available),
      FakeProvider(id: "codex", state: .notFound),
    ])

    let availabilities = await registry.availabilities(forceRefresh: false)

    #expect(availabilities[AgentProviderID("claude")]?.state == .available)
    #expect(availabilities[AgentProviderID("codex")]?.state == .notFound)
    #expect(await registry.diagnostics().map(\.providerID.rawValue) == ["claude", "codex"])
  }

  @Test("A slow provider does not prevent the others from answering")
  func slowProviderDoesNotBlockOthers() async {
    let registry = AgentProviderRegistry(providers: [
      FakeProvider(id: "slow", state: .available, delay: .milliseconds(200)),
      FakeProvider(id: "fast", state: .available),
    ])

    let clock = ContinuousClock()
    let start = clock.now
    let availabilities = await registry.availabilities(forceRefresh: false)
    let elapsed = clock.now - start

    #expect(availabilities.count == 2)
    // Probes run concurrently, so the total time stays close to the slowest one.
    #expect(elapsed < .milliseconds(600))
  }

  @Test("An empty registry is a valid, non failing state")
  func emptyRegistry() async {
    let registry = AgentProviderRegistry()

    #expect(await registry.descriptors().isEmpty)
    #expect(await registry.availabilities(forceRefresh: true).isEmpty)
  }
}

struct FakeProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  let delay: Duration

  init(id: String, state: AgentAvailabilityState = .available, delay: Duration = .zero) {
    descriptor = AgentDescriptor(id: AgentProviderID(id), displayName: id.capitalized)
    self.state = state
    self.delay = delay
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    if delay != .zero {
      try? await Task.sleep(for: delay)
    }
    return AgentDiagnosticFactory.availability(
      descriptor: descriptor,
      state: state,
      installation: nil,
      detail: nil,
      at: Date(timeIntervalSince1970: 0)
    )
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw AgentLaunchError.unavailable(state)
  }
}
