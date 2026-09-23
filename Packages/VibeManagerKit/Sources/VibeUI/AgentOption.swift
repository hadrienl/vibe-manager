import Foundation
import VibeApplication
import VibeDomain

/// One agent as a sheet offers it: what it is, and whether it can run right now.
public struct AgentOption: Identifiable, Sendable {
  public let descriptor: AgentDescriptor
  public let availability: AgentAvailability

  public init(descriptor: AgentDescriptor, availability: AgentAvailability) {
    self.descriptor = descriptor
    self.availability = availability
  }

  public var id: AgentProviderID { descriptor.id }
  public var isUsable: Bool { availability.isUsable }
  public var name: String { descriptor.displayName }
  public var status: String { availability.diagnostic.summary }
  public var remediations: [AgentRemediation] { availability.diagnostic.remediations }
  /// Shown next to an agent that cannot run: a diagnostic without a way out is a dead end.
  public var remedy: String { AgentRemediation.sentence(for: remediations) }

  /// Usable, yet worth a warning: the CLI runs, and asks for credentials itself in the
  /// terminal. Hiding that would make the first screen of the session a surprise.
  public var warnsBeforeLaunch: Bool {
    availability.state == .unauthenticated
  }

  /// Every registered agent, in registration order, the ones that cannot run included: an agent
  /// that disappears from the list teaches the user nothing.
  static func detect(
    in registry: any AgentProviderResolving,
    forceRefresh: Bool
  ) async -> [AgentOption] {
    let descriptors = await registry.descriptors()
    let availabilities = await registry.availabilities(forceRefresh: forceRefresh)
    return descriptors.compactMap { descriptor in
      availabilities[descriptor.id].map {
        AgentOption(descriptor: descriptor, availability: $0)
      }
    }
  }
}
