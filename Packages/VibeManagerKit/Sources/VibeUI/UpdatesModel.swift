import Foundation
import Observation
import VibeApplication

/// What the Updates tab and the application menu show of the updater (#92), kept in step with it.
@MainActor
@Observable
public final class UpdatesModel {
  @ObservationIgnored private let updater: any SoftwareUpdating

  public private(set) var availability: UpdateAvailability
  public private(set) var settings: UpdateSettings
  public private(set) var canCheck: Bool
  public private(set) var lastCheck: Date?
  public private(set) var waitingVersion: String?
  public private(set) var readyToInstall: UpdateCandidate?

  public init(updater: any SoftwareUpdating) {
    self.updater = updater
    availability = updater.availability
    settings = updater.settings
    canCheck = updater.canCheck
    lastCheck = updater.lastCheck
    waitingVersion = updater.waitingVersion
    readyToInstall = updater.readyToInstall
    updater.onChange = { [weak self] in self?.refresh() }
  }

  public var isAvailable: Bool { availability == .available }

  /// Changes one setting, and reads back what the updater kept.
  public func change(_ edit: (inout UpdateSettings) -> Void) {
    var changed = settings
    edit(&changed)
    guard changed != settings else { return }
    updater.settings = changed
    refresh()
  }

  public func checkNow() {
    updater.checkNow()
    refresh()
  }

  public func offerReadyUpdate() {
    updater.offerReadyUpdate()
    refresh()
  }

  func refresh() {
    availability = updater.availability
    settings = updater.settings
    canCheck = updater.canCheck
    lastCheck = updater.lastCheck
    waitingVersion = updater.waitingVersion
    readyToInstall = updater.readyToInstall
  }
}
