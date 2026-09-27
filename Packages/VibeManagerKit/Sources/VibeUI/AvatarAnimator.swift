import AppKit
import Observation
import VibeApplication

/// Drives `AvatarAnimation` in real time (#41): it sleeps until the next change the machine
/// announces, and publishes the expression to show. Nothing runs while it is stopped — the panel
/// hidden, the preview closed.
@MainActor
@Observable
public final class AvatarAnimator {
  public private(set) var expression: AvatarExpression = .neutral

  @ObservationIgnored private var animation: AvatarAnimation
  @ObservationIgnored private let clock = ContinuousClock()
  @ObservationIgnored private let origin: ContinuousClock.Instant
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var isRunning = false

  public init(reducesMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
    origin = clock.now
    animation = AvatarAnimation(
      reducesMotion: reducesMotion, seed: UInt64.random(in: 1...UInt64.max))
  }

  public var reducesMotion: Bool {
    get { animation.reducesMotion }
    set {
      animation.reducesMotion = newValue
      send(.tick)
    }
  }

  public func start() {
    guard !isRunning else { return }
    isRunning = true
    send(.tick)
  }

  public func stop() {
    isRunning = false
    timer?.cancel()
    timer = nil
  }

  /// Something happened: the machine says what to show, and until when.
  public func send(_ event: AvatarAnimation.Event) {
    let frame = animation.handle(event, at: clock.now - origin)
    expression = frame.expression
    timer?.cancel()
    guard isRunning, let next = frame.nextChange else { return }
    let deadline = origin + next
    timer = Task { [weak self] in
      try? await Task.sleep(until: deadline, clock: .continuous)
      guard !Task.isCancelled else { return }
      self?.send(.tick)
    }
  }
}
