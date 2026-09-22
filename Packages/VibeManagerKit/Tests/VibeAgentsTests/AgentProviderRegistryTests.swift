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
    // Concurrency is observed, not timed: the probes report when they are in flight, and the
    // test asks whether two ever were at once. A wall clock would only ask whether the machine
    // was busy — which is how this test used to fail on a loaded runner.
    let witness = ConcurrencyWitness()
    let registry = AgentProviderRegistry(providers: [
      // Both hold their probe open, so an overlap is certain when they run together and
      // impossible when they do not — no scheduling luck either way.
      FakeProvider(id: "slow", state: .available, delay: .milliseconds(50), witness: witness),
      FakeProvider(id: "fast", state: .available, delay: .milliseconds(50), witness: witness),
    ])

    let availabilities = await registry.availabilities(forceRefresh: false)

    #expect(availabilities.count == 2)
    #expect(await witness.peak == 2)
  }

  @Test("An empty registry is a valid, non failing state")
  func emptyRegistry() async {
    let registry = AgentProviderRegistry()

    #expect(await registry.descriptors().isEmpty)
    #expect(await registry.availabilities(forceRefresh: true).isEmpty)
  }
}

/// Counts how many probes were in flight at the same time.
actor ConcurrencyWitness {
  private(set) var peak = 0
  private var current = 0

  func enter() {
    current += 1
    peak = max(peak, current)
  }

  func leave() {
    current -= 1
  }
}

struct FakeProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  let delay: Duration
  let witness: ConcurrencyWitness?

  init(
    id: String,
    state: AgentAvailabilityState = .available,
    delay: Duration = .zero,
    witness: ConcurrencyWitness? = nil
  ) {
    descriptor = AgentDescriptor(id: AgentProviderID(id), displayName: id.capitalized)
    self.state = state
    self.delay = delay
    self.witness = witness
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    await witness?.enter()
    if delay != .zero {
      try? await Task.sleep(for: delay)
    }
    await witness?.leave()
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
