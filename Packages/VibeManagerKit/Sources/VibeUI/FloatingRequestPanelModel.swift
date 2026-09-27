import Foundation
import Observation
import VibeApplication

/// The requests shown above the other applications, by an avatar in a bubble (#41).
///
/// A second view of the palette of #40, never a second palette: the same `PendingRequest`s,
/// answered through the same `AppModel.answer(_:to:)`. It only decides whether it is on screen,
/// which request its bubble shows, and whether it is folded.
@MainActor
@Observable
public final class FloatingRequestPanelModel {
  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private let preferences: any FloatingPanelPreferences

  /// Requests shown above the other applications. Off by default: #40 unchanged.
  public var isEnabled: Bool {
    didSet {
      preferences.showsFloatingPanel = isEnabled
      app?.requestsDidChange()
    }
  }
  public var idle: FloatingPanelIdle {
    didSet { preferences.idle = idle }
  }
  /// Folded into the avatar alone. Kept across launches.
  public var isCollapsed: Bool {
    didSet { preferences.isCollapsed = isCollapsed }
  }
  /// The request the user moved the bubble to. `nil`, or gone: the oldest.
  public private(set) var chosenRequestID: AgentRequestID?
  /// ⌃⌥⌘P: the bubble takes the keyboard.
  public internal(set) var focusRequest = 0

  public init(preferences: any FloatingPanelPreferences) {
    self.preferences = preferences
    isEnabled = preferences.showsFloatingPanel
    idle = preferences.idle
    isCollapsed = preferences.isCollapsed
  }

  func attach(_ app: AppModel) {
    self.app = app
  }

  // MARK: - What it shows

  /// Every request waiting, the selected session's included: when the panel is on screen, the
  /// user is not looking at Vibe Manager, and nobody types into that session's terminal.
  public var requests: [PendingRequest] { app?.allPendingRequests ?? [] }

  /// Whether the panel is on screen: on, and Vibe Manager not in front with its window — then the
  /// sidebar has its palette, and the same request is never shown twice.
  public var isShown: Bool {
    guard isEnabled, let app else { return false }
    guard !(app.isApplicationActive && app.isMainWindowVisible) else { return false }
    // The outcome keeps it only while the bubble shows it: that line is what clears it, and folded
    // it would never be cleared, leaving the avatar above everything.
    return !requests.isEmpty || idle == .avatarOnly || (app.requestOutcome != nil && !isCollapsed)
  }

  /// The request in the bubble: the one the user moved to while it waits, else the oldest.
  public var current: PendingRequest? {
    let requests = requests
    return requests.first { $0.id == chosenRequestID } ?? requests.first
  }

  /// "2 / 3": where the bubble is among the requests.
  public var position: (index: Int, count: Int)? {
    let requests = requests
    guard let current, let index = requests.firstIndex(where: { $0.id == current.id }) else {
      return nil
    }
    return (index + 1, requests.count)
  }

  /// What the avatar "reads out" of a request: its session and what it asks.
  public static func speech(of pending: PendingRequest) -> String {
    let title = String(localized: RequestPresentation.title(of: pending.request.content))
    return [pending.session.name, title, RequestPresentation.subject(of: pending.request.content)]
      .compactMap { $0 }.joined(separator: " ")
  }

  // MARK: - Gestures

  /// The next request, or the previous, stopping at both ends.
  public func show(offset: Int) {
    let requests = requests
    guard let position else { return }
    let index = min(max(position.index - 1 + offset, 0), requests.count - 1)
    chosenRequestID = requests[index].id
  }

  public func toggleCollapsed() {
    isCollapsed.toggle()
  }

  /// ⌃⌥⌘P: unfolds the bubble and asks it to take the keyboard.
  public func focus() {
    isCollapsed = false
    focusRequest += 1
  }

  /// Back to their default place on every screen.
  public func resetPositions() {
    preferences.anchors = [:]
    positionResetCount += 1
  }

  /// Told to the window when the positions were reset.
  public private(set) var positionResetCount = 0

  public func anchor(forDisplay key: String) -> FloatingPanelAnchor? {
    preferences.anchors[key]
  }

  public func setAnchor(_ anchor: FloatingPanelAnchor, forDisplay key: String) {
    preferences.anchors[key] = anchor
  }
}
