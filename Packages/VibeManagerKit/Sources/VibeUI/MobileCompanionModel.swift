import Foundation
import Observation

/// The mobile companion as Settings › iPhone Companion shows it (#397): whether it runs, what its
/// agent says of iCloud, and the iPhones admitted to the direct channel (#398).
///
/// Off until the user turns it on: the agent, which holds iCloud and listens for the phones, is
/// started only then, and stopped — the Mac said offline — when it is turned off.
@MainActor
@Observable
public final class MobileCompanionModel {
  /// Whether this Mac can run the companion at all.
  public enum Availability: Equatable, Sendable {
    case available
    /// A build without the agent: a contributor's, without the team's App IDs.
    case notEmbedded
    /// The agent's network library ships for Apple silicon only.
    case needsAppleSilicon
  }

  public enum AgentState: Equatable, Sendable {
    case off
    case starting
    /// Running, iCloud signed in, reachable by the phones.
    case running
    /// Running, without an iCloud account to publish in.
    case noAccount
    case failed
  }

  /// An iPhone admitted to the direct channel: its endpoint written in the user's iCloud.
  public struct Phone: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let addedAt: Date

    public init(id: String, name: String, addedAt: Date) {
      self.id = id
      self.name = name
      self.addedAt = addedAt
    }
  }

  public static let enabledKey = "companion.enabled"

  public let availability: Availability
  public private(set) var state: AgentState = .off
  public private(set) var phones: [Phone] = []
  /// The phones connected now, by endpoint.
  public private(set) var connectedPhones: Set<String> = []

  public var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      defaults.set(isEnabled, forKey: Self.enabledKey)
      if !isEnabled {
        state = .off
        connectedPhones = []
      }
      enabledChanged?(isEnabled)
    }
  }

  @ObservationIgnored private let defaults: UserDefaults
  /// Starts or stops the agent: set by the composition.
  @ObservationIgnored public var enabledChanged: ((Bool) -> Void)?
  /// Removes a phone's record from iCloud: set by the composition.
  @ObservationIgnored public var removePhoneAction: ((String) -> Void)?

  public init(availability: Availability, defaults: UserDefaults = .standard) {
    self.availability = availability
    self.defaults = defaults
    isEnabled = availability == .available && defaults.bool(forKey: Self.enabledKey)
  }

  public var canRun: Bool { availability == .available }

  /// What the agent says, as it says it.
  public func update(state: AgentState) {
    guard isEnabled || state == .off else { return }
    self.state = state
  }

  public func update(phones: [Phone]) {
    self.phones = phones.sorted { $0.addedAt > $1.addedAt }
  }

  public func update(connected: Set<String>) {
    connectedPhones = connected
  }

  /// No longer admitted: its record leaves iCloud, and the Mac refuses it from then on. Opening the
  /// app on that phone writes it again: removing is for a phone given away or lost.
  public func remove(_ phone: Phone) {
    phones.removeAll { $0.id == phone.id }
    removePhoneAction?(phone.id)
  }
}
