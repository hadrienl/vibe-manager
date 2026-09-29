import AppKit
import Security
import Sparkle
import VibeApplication

/// The application's updater (#92, ADR 0033): Sparkle 2, reading the feed published on GitHub
/// Pages, and installing an archive only when both its EdDSA signature and its Developer ID
/// signature check out.
///
/// Its window is Sparkle's own — release notes, Install and Relaunch, Remind Me Later, Skip This
/// Version — in the user's language. What is the application's is when a relaunch may happen:
/// `relaunchGate` is asked before any, and answers once the question of ADR 0017 is settled.
@MainActor
public final class SparkleSoftwareUpdater: NSObject, SoftwareUpdating {
  public private(set) var availability: UpdateAvailability
  public var onChange: (() -> Void)?
  /// A version found by a scheduled check while the user was busy, waiting to be looked at: the
  /// gentle reminder, said in the menu rather than by a window that would take the focus.
  public private(set) var waitingVersion: String?

  /// A version downloaded and ready, whose relaunch waits for the application's answer: asked
  /// now, or set aside by Later, until the menu offers it again or the application quits — Sparkle
  /// installs it then, whatever was answered.
  public private(set) var readyToInstall: UpdateCandidate?
  private var installReady: (() -> Void)?

  /// Asked when an update is ready to relaunch the application. It answers with
  /// `installReadyUpdate()` once the user agreed and nothing is in the way, or
  /// `setReadyUpdateAside()` for Later.
  public var relaunchGate: ((UpdateCandidate) -> Void)?
  /// Told when an update was given up on, whatever the reason: a failed download, a refused
  /// signature, an installer that did not start.
  public var onAbort: (() -> Void)?
  /// Whether a sheet or an alert is open: a scheduled check says nothing over it.
  public var isPresentingModal: () -> Bool = { false }

  private var updater: SPUUpdater?
  private var userDriver: SPUStandardUserDriver?
  private let defaults: UserDefaults
  private var observations: [NSKeyValueObservation] = []

  static let channelKey = "UpdateChannel"

  public init(
    bundle: Bundle = .main,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    availability = UpdateAvailability.evaluate(
      environment: environment,
      isSignedWithDeveloperID: Self.isSignedWithDeveloperID(),
      hasPublicKey: !(key ?? "").isEmpty)
    super.init()
    guard availability == .available else { return }

    let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
    let updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
    do {
      try updater.start()
    } catch {
      availability = .unavailable(.failed)
      return
    }
    self.userDriver = userDriver
    self.updater = updater
    observations = [
      updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
        Task { @MainActor in self?.onChange?() }
      },
      updater.observe(\.sessionInProgress) { [weak self] _, _ in
        Task { @MainActor in self?.onChange?() }
      },
    ]
  }

  public var settings: UpdateSettings {
    get {
      var settings = UpdateSettings(channel: channel)
      guard let updater else { return settings }
      settings.automaticallyChecks = updater.automaticallyChecksForUpdates
      settings.interval = UpdateCheckInterval(seconds: updater.updateCheckInterval)
      settings.automaticallyDownloads = updater.automaticallyDownloadsUpdates
      return settings
    }
    set {
      guard let updater else { return }
      if newValue.automaticallyChecks != updater.automaticallyChecksForUpdates {
        updater.automaticallyChecksForUpdates = newValue.automaticallyChecks
      }
      if newValue.interval.seconds != updater.updateCheckInterval {
        updater.updateCheckInterval = newValue.interval.seconds
      }
      if newValue.automaticallyDownloads != updater.automaticallyDownloadsUpdates {
        updater.automaticallyDownloadsUpdates = newValue.automaticallyDownloads
      }
      channel = newValue.channel
      onChange?()
    }
  }

  public var canCheck: Bool {
    updater?.canCheckForUpdates ?? false
  }

  public var lastCheck: Date? {
    updater?.lastUpdateCheckDate
  }

  public func checkNow() {
    updater?.checkForUpdates()
  }

  /// Whether the version that is ready can be installed now, with a relaunch: `false` once that
  /// was started — a quit then cancelled leaves it to be installed at the next quit.
  public var canOfferReadyUpdate: Bool {
    readyToInstall != nil && installReady != nil
  }

  /// Asks again about the version set aside by Later.
  public func offerReadyUpdate() {
    guard canOfferReadyUpdate, let readyToInstall, let relaunchGate else { return }
    relaunchGate(readyToInstall)
  }

  /// Quits, installs and relaunches: the answer to the question is in. `false` when there was
  /// nothing left to start — the update was given up on, or is already on its way.
  @discardableResult
  public func installReadyUpdate() -> Bool {
    guard let install = installReady else { return false }
    installReady = nil
    onChange?()
    install()
    return true
  }

  /// Later: Sparkle's window goes away rather than waiting on a relaunch nobody will start, and
  /// the version stays ready, offered by the menu and installed when the application quits.
  public func setReadyUpdateAside() {
    userDriver?.dismissUpdateInstallation()
    onChange?()
  }

  /// Kept apart from Sparkle's own defaults: the channel is the application's choice, handed to
  /// Sparkle at each check.
  private var channel: UpdateChannel {
    get { defaults.string(forKey: Self.channelKey).flatMap(UpdateChannel.init) ?? .stable }
    set { defaults.set(newValue.rawValue, forKey: Self.channelKey) }
  }

  /// Whether this process is signed with a Developer ID, as a release is. A build of the source is
  /// signed Apple Development or ad hoc, and a release must never replace it.
  static func isSignedWithDeveloperID() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var requirement: SecRequirement?
    let developerID =
      "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    guard
      SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }
}

extension SparkleSoftwareUpdater: SPUUpdaterDelegate {
  /// The unstable channel sees the release candidates besides the final versions; the stable one
  /// sees only those.
  public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    Self.allowedChannels(for: channel)
  }

  nonisolated static func allowedChannels(for channel: UpdateChannel) -> Set<String> {
    switch channel {
    case .stable: []
    case .unstable: [UpdateChannel.unstable.rawValue]
    }
  }

  /// Installing is quitting: the relaunch waits for the application's answer.
  public func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    guard let relaunchGate else { return false }
    let candidate = Self.candidate(of: item)
    readyToInstall = candidate
    installReady = installHandler
    onChange?()
    relaunchGate(candidate)
    return true
  }

  public func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
  ) {
    onChange?()
  }

  /// Downloaded by itself, to be installed as the application quits: the same version is ready as
  /// one set aside by Later, and the same question guards it — at that quit, or from the menu.
  public func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    readyToInstall = Self.candidate(of: item)
    installReady = immediateInstallHandler
    onChange?()
    return true
  }

  public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    readyToInstall = nil
    installReady = nil
    onAbort?()
    onChange?()
  }

  static func candidate(of item: SUAppcastItem) -> UpdateCandidate {
    candidate(version: item.displayVersionString, properties: item.propertiesDictionary)
  }

  /// Sparkle keeps an element of another namespace under its prefixed name, as a string.
  nonisolated static func candidate(version: String, properties: [AnyHashable: Any])
    -> UpdateCandidate
  {
    let hostProtocol = (properties["vibe:hostProtocol"] as? String).flatMap {
      Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return UpdateCandidate(version: version, hostProtocol: hostProtocol)
  }
}

// Not isolated to the main actor in Sparkle's headers, though Sparkle calls it on the main thread
// only, as it does everything of its user driver.
extension SparkleSoftwareUpdater: SPUStandardUserDriverDelegate {
  /// A scheduled check never steals the focus from a terminal being typed in.
  public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Shown at once when the application has just come forward, and never over a sheet: then the
  /// menu says a version is waiting, and choosing it opens the window.
  public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    MainActor.assumeIsolated { immediateFocus && !isPresentingModal() }
  }

  public nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    guard !handleShowingUpdate, !state.userInitiated else { return }
    let version = update.displayVersionString
    MainActor.assumeIsolated {
      waitingVersion = version
      onChange?()
    }
  }

  public nonisolated func standardUserDriverDidReceiveUserAttention(
    forUpdate update: SUAppcastItem
  ) {
    MainActor.assumeIsolated { lookedAt() }
  }

  public nonisolated func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated { lookedAt() }
  }

  private func lookedAt() {
    waitingVersion = nil
    onChange?()
  }
}
