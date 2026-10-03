import VibeDomain

/// Where the first launch's tour (#338) stands, kept across launches.
///
/// Read synchronously, like the other interface preferences: whether a bubble shows is decided
/// while the window is drawn.
@MainActor
public protocol OnboardingPreferences: AnyObject {
  var tour: OnboardingTour { get set }
  /// The interface smoke tests, and the copies made to test a build, start without the tour.
  var isTourSuppressed: Bool { get }
}

/// Kept for this run only. What a workspace assembled without the system around it uses: the tour
/// is over there unless a test says otherwise.
@MainActor
public final class InMemoryOnboardingPreferences: OnboardingPreferences {
  public var tour: OnboardingTour
  public let isTourSuppressed: Bool

  public init(tour: OnboardingTour = .finished, isTourSuppressed: Bool = false) {
    self.tour = tour
    self.isTourSuppressed = isTourSuppressed
  }
}
