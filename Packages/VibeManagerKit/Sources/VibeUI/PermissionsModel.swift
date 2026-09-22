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

  /// Reads the status and decides whether the step has anything to say. Called at launch — never
  /// from the session-creation flow, which is the whole point.
  ///
  /// It can raise the step but never lowers it: the gate only ever says yes once per launch, so
  /// a second caller asking the question would otherwise close a step the user is reading.
  public func refresh() async {
    status = await gate.status()
    if await gate.shouldPresentStep() {
      isPresentingStep = true
    }
  }

  /// Asks the system again, for a screen the user opened themselves.
  ///
  /// Someone opening the settings window has usually just come back from System Settings, and a
  /// row still reading "Not granted" from a decision taken at launch would be a row that lies.
  public func recheck() async {
    status = await gate.refreshedStatus()
  }

  /// Opens the right pane of System Settings, and nothing else.
  ///
  /// Reaching that pane is not an answer to the step: the settings window offers the same button,
  /// and a user who opens it before the step has ever been shown would otherwise lose the step for
  /// good by clicking there and then changing their mind.
  public func openSystemSettings() {
    openURL(Self.fullDiskAccessSettingsURL)
  }

  /// The step's own default button: opens the pane and closes the step.
  ///
  /// The step does not wait for the user to come back: the switch they are about to flip only
  /// reaches this application at its next launch, so there is nothing here left to wait for.
  /// System Settings offers "Quit & Reopen" itself, and that offer is better placed than ours.
  public func answerStepByOpeningSystemSettings() async {
    openSystemSettings()
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
