import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

private actor EmptyRepository: SessionRepository {
  func sessions() -> [WorkSession] { [] }
  func session(id: SessionID) -> WorkSession? { nil }
  func save(_: WorkSession) {}
}

private struct StubAgentProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  /// Holds the detection until the test opens it.
  let gate: ProbeGate?

  init(id: String, state: AgentAvailabilityState, gate: ProbeGate? = nil) {
    descriptor = AgentDescriptor(id: AgentProviderID(id), displayName: id.capitalized)
    self.state = state
    self.gate = gate
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    await gate?.wait()
    return AgentAvailability(
      state: state,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: state,
        summary: "\(descriptor.displayName) state",
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

private struct StubAgentRegistry: AgentProviderResolving {
  let providers: [StubAgentProvider]

  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }

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

@MainActor
@Test("Loading exposes the agent diagnostics in registration order")
func appModelExposesAgentDiagnostics() async {
  let model = AppModel(
    repository: EmptyRepository(),
    agents: StubAgentRegistry(providers: [
      StubAgentProvider(id: "claude", state: .available),
      StubAgentProvider(id: "codex", state: .notFound),
    ])
  )

  await model.load()

  #expect(model.agentDiagnostics.map(\.providerID.rawValue) == ["claude", "codex"])
  #expect(model.agentDiagnostics.last?.state == .notFound)
}

@MainActor
@Test("An agent that answered is shown without waiting for one that has not")
func aFastAgentIsNotHeldBehindASlowOne() async {
  let slow = ProbeGate()
  let model = AppModel(
    repository: EmptyRepository(),
    agents: StubAgentRegistry(providers: [
      StubAgentProvider(id: "claude", state: .available, gate: slow),
      StubAgentProvider(id: "codex", state: .notFound),
    ])
  )

  let refresh = Task { await model.refreshAgents() }
  // Claude answers only once the test says so, whatever the speed of the machine.
  let deadline = ContinuousClock.now + .seconds(10)
  while model.agentDiagnostics.isEmpty, ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(10))
  }

  // A CLI that answers none of its probes costs three budgets and their retries. Holding the
  // agents that answered straight away behind it is what this avoids.
  #expect(model.agentDiagnostics.map(\.providerID.rawValue) == ["codex"])

  await slow.open()
  await refresh.value

  // And the registration order is restored once everything has landed.
  #expect(model.agentDiagnostics.map(\.providerID.rawValue) == ["claude", "codex"])
}

@MainActor
@Test("An unavailable agent never turns the application into a failed state")
func unavailableAgentDoesNotFailTheApp() async {
  let model = AppModel(
    repository: EmptyRepository(),
    agents: StubAgentRegistry(providers: [
      StubAgentProvider(id: "codex", state: .probeFailed(reason: .timedOut))
    ])
  )

  await model.load()

  #expect(model.state == .loaded([]))
  #expect(model.agentDiagnostics.count == 1)
}

@MainActor
@Test("A session whose provider disappeared is reported as not resumable")
func sessionWithRetiredProviderIsNotResumable() async {
  let model = AppModel(
    repository: EmptyRepository(),
    agents: StubAgentRegistry(providers: [StubAgentProvider(id: "claude", state: .available)])
  )

  let retired = WorkSession(
    name: "Old session",
    agent: SessionAgentConfiguration(providerID: "retired", modelID: "whatever")
  )
  let current = WorkSession(
    name: "Current session",
    agent: SessionAgentConfiguration(providerID: "claude", modelID: "sonnet")
  )

  #expect(await model.resolution(for: retired) == .unknownProvider("retired"))
  #expect(await model.resolution(for: current).isResumable)
}

@MainActor
@Test("Without a registry the application still loads")
func appModelWorksWithoutRegistry() async {
  let model = AppModel(repository: EmptyRepository())

  await model.load()

  #expect(model.state == .loaded([]))
  #expect(model.agentDiagnostics.isEmpty)
}
