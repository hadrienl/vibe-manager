import Foundation

/// What the application knows about its own access to the user's protected folders.
///
/// Two states, not three. macOS exposes no status API for Full Disk Access, and nothing lets a
/// process tell "never asked" from "refused": both look exactly alike from inside. A third case
/// would be an invention, and every screen that read it would be showing a guess.
public enum FullDiskAccessStatus: Hashable, Sendable {
  case granted
  case notGranted
}

/// Answers whether this process has Full Disk Access, without asking for it.
///
/// There is no system call for the question, so the answer is empirical: read something only that
/// access opens. The probe must never be the thing that raises an alert — see
/// `TCCFullDiskAccessProbe` for the witness that was chosen and why it stays silent.
public protocol FullDiskAccessProbe: Sendable {
  func status() async -> FullDiskAccessStatus
}

/// What the application remembers about permission steps the user has already seen.
///
/// Only decisions the user made are kept here. Whether access is granted is never written down:
/// it is read from the system every launch, so an access revoked in System Settings cannot leave
/// the application repeating something that stopped being true.
public protocol PermissionPreferences: Sendable {
  func isFullDiskAccessStepDismissed() async -> Bool
  func dismissFullDiskAccessStep() async
}

/// Decides whether the Full Disk Access step has anything to say, and remembers the answer.
///
/// The status is probed once per launch and cached, because it cannot change under a running
/// process: TCC freezes a process's permissions when it starts, which is the same reason the step
/// has to tell the user that the change only takes effect at the next launch.
public actor FullDiskAccessGate {
  private let probe: any FullDiskAccessProbe
  private let preferences: any PermissionPreferences
  private var cachedStatus: FullDiskAccessStatus?

  public init(probe: any FullDiskAccessProbe, preferences: any PermissionPreferences) {
    self.probe = probe
    self.preferences = preferences
  }

  public func status() async -> FullDiskAccessStatus {
    if let cachedStatus { return cachedStatus }
    let status = await probe.status()
    cachedStatus = status
    return status
  }

  /// Whether the one-time step should be presented at this launch.
  ///
  /// | Status       | Step dismissed | Presented |
  /// |--------------|----------------|-----------|
  /// | `granted`    | —              | no        |
  /// | `notGranted` | no             | **yes**   |
  /// | `notGranted` | yes            | no        |
  public func shouldPresentStep() async -> Bool {
    guard await status() == .notGranted else { return false }
    return await !preferences.isFullDiskAccessStepDismissed()
  }

  /// Records that the user answered the step — by granting access or by skipping it. Either way
  /// it is an answer, and an answer is not asked for twice.
  public func dismissStep() async {
    await preferences.dismissFullDiskAccessStep()
  }
}
