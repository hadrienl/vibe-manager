import AppKit
import Foundation
import Observation
import VibeApplication

/// The application's side of the one permission macOS grants once and for all.
///
/// It holds a status that is read at launch and then left alone: TCC freezes a process's
/// permissions when it starts, so re-probing during the session could only ever repeat the same
/// answer — and it is the same fact that makes the step say the change takes effect at the next
/// launch.
@MainActor
@Observable
public final class PermissionsModel {
  /// The pane of System Settings that holds the switch. Opened, never automated: Full Disk Access
  /// cannot be requested programmatically, by design.
  public static let fullDiskAccessSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  )!

  /// `nil` until the first probe has answered. "Not probed yet" and "not granted" are different
  /// things, and the settings row says so rather than accusing the system of a refusal it has not
  /// been asked about.
  public private(set) var status: FullDiskAccessStatus?
  public private(set) var isPresentingStep = false

  private let gate: FullDiskAccessGate
  private let openURL: @MainActor (URL) -> Void

  public init(
    gate: FullDiskAccessGate,
    openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
  ) {
    self.gate = gate
    self.openURL = openURL
  }

  public var isGranted: Bool {
    status == .granted
  }

  /// Reads the status once and decides whether the step has anything to say. Called at launch,
  /// after the window is up — never from the session-creation flow, which is the whole point.
  public func refresh() async {
    status = await gate.status()
    isPresentingStep = await gate.shouldPresentStep()
  }

  /// Opens the right pane of System Settings and closes the step.
  ///
  /// The step does not wait for the user to come back: the switch they are about to flip only
  /// reaches this application at its next launch, so there is nothing here left to wait for.
  /// System Settings offers "Quit & Reopen" itself, and that offer is better placed than ours.
  public func openSystemSettings() async {
    openURL(Self.fullDiskAccessSettingsURL)
    await dismissStep()
  }

  /// Skipping is an answer too. The application keeps working, and the step is not asked again.
  public func skipStep() async {
    await dismissStep()
  }

  private func dismissStep() async {
    isPresentingStep = false
    await gate.dismissStep()
  }
}
