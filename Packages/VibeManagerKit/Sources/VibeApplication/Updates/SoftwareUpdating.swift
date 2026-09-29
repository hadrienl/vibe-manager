import Foundation

/// Which releases a copy of the application is offered (#92).
public enum UpdateChannel: String, CaseIterable, Sendable {
  /// Final versions only.
  case stable
  /// Final versions and release candidates, `1.2.0-rc.1`: the channel the feed names `unstable`.
  case unstable
}

/// How often the application looks for a new version by itself.
public enum UpdateCheckInterval: String, CaseIterable, Sendable {
  case daily
  case weekly
  case monthly

  public var seconds: TimeInterval {
    switch self {
    case .daily: 86_400
    case .weekly: 604_800
    case .monthly: 2_592_000
    }
  }

  /// The closest of the three to an interval set some other way, `defaults write` included.
  public init(seconds: TimeInterval) {
    self =
      Self.allCases.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .daily
  }
}

/// What the user chose about updates.
public struct UpdateSettings: Equatable, Sendable {
  /// On by default: a copy nobody updates is a copy that keeps its bugs.
  public var automaticallyChecks: Bool
  public var interval: UpdateCheckInterval
  /// Off by default: the user is told first. On, a version is downloaded as soon as it is found and
  /// installed when the application quits — never while it runs.
  public var automaticallyDownloads: Bool
  public var channel: UpdateChannel

  public init(
    automaticallyChecks: Bool = true,
    interval: UpdateCheckInterval = .daily,
    automaticallyDownloads: Bool = false,
    channel: UpdateChannel = .stable
  ) {
    self.automaticallyChecks = automaticallyChecks
    self.interval = interval
    self.automaticallyDownloads = automaticallyDownloads
    self.channel = channel
  }
}

/// Whether this copy of the application updates itself.
public enum UpdateAvailability: Equatable, Sendable {
  case available
  case unavailable(Reason)

  public enum Reason: Equatable, Sendable {
    /// Not signed with the team's Developer ID: a build of the source, which a release must never
    /// replace.
    case developmentBuild
    /// A copy with a data directory of its own (`VIBE_DATA_DIRECTORY`), run beside the real one,
    /// unless `VIBE_UPDATES=on` says it is there to test an update (`Scripts/update-check.sh`).
    case isolatedCopy
    /// `VIBE_UPDATES=off`.
    case turnedOff
    /// Built without the key that proves an update comes from the maintainer.
    case notConfigured
    /// The updater would not start.
    case failed
  }

  /// Decided once, at launch, from what the process is.
  public static func evaluate(
    environment: [String: String], isSignedWithDeveloperID: Bool, hasPublicKey: Bool
  ) -> UpdateAvailability {
    switch environment["VIBE_UPDATES"] {
    case "off":
      return .unavailable(.turnedOff)
    case "on":
      break
    default:
      if !(environment["VIBE_DATA_DIRECTORY"] ?? "").isEmpty { return .unavailable(.isolatedCopy) }
    }
    guard isSignedWithDeveloperID else { return .unavailable(.developmentBuild) }
    guard hasPublicKey else { return .unavailable(.notConfigured) }
    return .available
  }
}

/// A version the feed offers, as far as the application cares before installing it.
public struct UpdateCandidate: Equatable, Sendable {
  /// `1.2.0`, or `1.2.0-rc.1`.
  public var version: String
  /// The core of the terminal host's protocol that version speaks (ADR 0017), when the feed says.
  public var hostProtocol: Int?

  public init(version: String, hostProtocol: Int?) {
    self.version = version
    self.hostProtocol = hostProtocol
  }
}

/// The application's updater (#92): Sparkle in the application, a double in the tests.
///
/// Everything it does happens on the main thread, where its window is.
@MainActor
public protocol SoftwareUpdating: AnyObject {
  var availability: UpdateAvailability { get }
  var settings: UpdateSettings { get set }
  /// `false` while a check is already under way, or when updates are unavailable.
  var canCheck: Bool { get }
  var lastCheck: Date? { get }
  /// A version a scheduled check found while the user was busy, not yet looked at.
  var waitingVersion: String? { get }
  /// Looks now, and says what it found in a window, even that there is nothing new.
  func checkNow()
  /// Called whenever `canCheck`, `lastCheck` or `settings` changed on the updater's side.
  var onChange: (() -> Void)? { get set }
}
