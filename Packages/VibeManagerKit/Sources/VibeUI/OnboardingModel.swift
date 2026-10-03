import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The first launch's tour (#338): where it stands, kept as it moves, and what each bubble says.
///
/// It only listens. `AppModel` tells it what the user did — a draft opened, a session made, a
/// status changed — at the places those already happen; it never creates or starts anything.
@MainActor
@Observable
public final class OnboardingModel {
  public private(set) var tour: OnboardingTour
  @ObservationIgnored private let preferences: any OnboardingPreferences

  public init(preferences: any OnboardingPreferences) {
    self.preferences = preferences
    tour = preferences.isTourSuppressed ? .finished : preferences.tour
  }

  /// The status the tour's session was last seen in, to see it move In Progress.
  @ObservationIgnored private var observedStatus: SessionTaskStatus?
  /// Not for a session created launched: it goes through To Do on its way, and was not moved.
  @ObservationIgnored private var watchesForStart = true

  public var step: OnboardingStep? { tour.step }
  public var sessionID: SessionID? { tour.sessionID }

  public func send(_ event: OnboardingEvent) {
    if case .created(_, let launched) = event {
      watchesForStart = !launched
      observedStatus = nil
    }
    let next = tour.applying(event)
    guard next != tour else { return }
    tour = next
    // A suppressed tour leaves the user's preferences as it found them.
    if !preferences.isTourSuppressed { preferences.tour = next }
  }

  /// Every list the workspace holds. The tour's session seen going from To Do to In Progress, by
  /// whatever way — a swipe, its menu, Start Session — is the move the statuses bubble asks for.
  func observe(_ sessions: [WorkSession]) {
    guard step == .statuses, watchesForStart, let id = sessionID,
      let status = sessions.first(where: { $0.id == id })?.taskStatus
    else {
      observedStatus = nil
      return
    }
    let previous = observedStatus
    observedStatus = status
    if previous == .todo, status == .doing { send(.taskStatusChanged(id, .doing)) }
  }

  /// At launch, once the sessions are read.
  func resume(hasSessions: Bool, contains: (SessionID) -> Bool) {
    guard !preferences.isTourSuppressed else { return }
    let resumed = tour.resumed(hasSessions: hasSessions, contains: contains)
    guard resumed != tour else { return }
    tour = resumed
    preferences.tour = resumed
  }

  // MARK: - Bubbles

  /// What a bubble says, and whether it offers to go on without the gesture it waits for.
  struct Bubble: Equatable {
    enum Advance: Equatable {
      case next
      case done
    }

    let title: String
    let message: String
    /// "Step 2 of 6"; `nil` on the closing bubble.
    let progress: String?
    let advance: Advance?

    /// What VoiceOver says when the bubble appears.
    var announcement: String { "\(title). \(message)" }
  }

  /// - Parameters:
  ///   - hasFolder: whether the draft has a working folder already, at the folder step.
  ///   - waitsInToDo: whether the tour's session is in To Do, at the statuses step.
  static func bubble(
    for step: OnboardingStep, hasFolder: Bool = false, waitsInToDo: Bool = false
  ) -> Bubble {
    let progress = step.number.map {
      String(
        localized: "Step \($0) of \(OnboardingStep.counted.count)", bundle: .module,
        comment: "The tutorial's progress: the step on screen, then how many there are.")
    }
    switch step {
    case .newSession:
      return Bubble(
        title: String(
          localized: "Start your first session", bundle: .module,
          comment: "Tutorial, pointing at New Session."),
        message: String(
          localized:
            "A session is an agent working in a folder, with its conversation, notes and progress. Click New Session to start one.",
          bundle: .module, comment: "Tutorial, pointing at New Session."),
        progress: progress, advance: nil)
    case .name:
      return Bubble(
        title: String(
          localized: "Name it", bundle: .module,
          comment: "Tutorial, pointing at the new session's name."),
        message: String(
          localized:
            "The name tells your sessions apart in the sidebar. Leave it empty and it is taken from your prompt.",
          bundle: .module, comment: "Tutorial, pointing at the new session's name."),
        progress: progress, advance: .next)
    case .folder:
      return Bubble(
        title: String(
          localized: "Choose the folder", bundle: .module,
          comment: "Tutorial, pointing at the new session's working folder."),
        message: String(
          localized: "The agent works in this folder. Choose the project it should work on.",
          bundle: .module, comment: "Tutorial, pointing at the new session's working folder."),
        progress: progress, advance: hasFolder ? .next : nil)
    case .options:
      return Bubble(
        title: String(
          localized: "Pick the agent", bundle: .module,
          comment: "Tutorial, pointing at the new session's agent and model."),
        message: String(
          localized:
            "Choose the agent and its model. The badge next to the name sets the icon and colour, and More Options links a ticket. Then write in the prompt below.",
          bundle: .module, comment: "Tutorial, pointing at the new session's agent and model."),
        progress: progress, advance: .next)
    case .prompt:
      return Bubble(
        title: String(
          localized: "Write the first message", bundle: .module,
          comment: "Tutorial, pointing at the new session's prompt."),
        message: String(
          localized:
            "What you write here is the first message sent to the agent. Click Add to To Do to keep the session for later.",
          bundle: .module, comment: "Tutorial, pointing at the new session's prompt."),
        progress: progress, advance: nil)
    case .statuses:
      return Bubble(
        title: waitsInToDo
          ? String(
            localized: "Move it to In Progress", bundle: .module,
            comment: "Tutorial, pointing at the new session's row, which waits in To Do.")
          : String(
            localized: "Change its status", bundle: .module,
            comment: "Tutorial, pointing at the new session's row."),
        message: waitsInToDo
          ? String(
            localized:
              "Swipe a session with two fingers on the trackpad, or right-click it, to change its status. Move this one to In Progress to start its agent.",
            bundle: .module,
            comment: "Tutorial, pointing at the new session's row, which waits in To Do.")
          : String(
            localized:
              "Swipe a session with two fingers on the trackpad, or right-click it, to change its status as the work goes on.",
            bundle: .module, comment: "Tutorial, pointing at the new session's row."),
        progress: progress, advance: waitsInToDo ? nil : .next)
    case .finale:
      return Bubble(
        title: String(
          localized: "You’re all set", bundle: .module,
          comment: "Tutorial, the closing bubble."),
        message: String(
          localized: "Your agent is at work. Good luck!", bundle: .module,
          comment: "Tutorial, the closing bubble."),
        progress: nil, advance: .done)
    }
  }
}

/// What a bubble of the tour can point at.
enum TourTarget: Hashable {
  /// New Session in the empty window.
  case emptyStateNewSession
  /// New Session in the toolbar, when the window shows a session.
  case toolbarNewSession
  case draftName
  case draftFolder
  case draftOptions
  case draftComposer
  case sessionRow(SessionID)
}

extension OnboardingStep {
  /// What the step's bubble points at in the draft, if it lives there.
  var draftTarget: TourTarget? {
    switch self {
    case .name: .draftName
    case .folder: .draftFolder
    case .options: .draftOptions
    case .prompt: .draftComposer
    case .newSession, .statuses, .finale: nil
    }
  }
}

extension AppModel {
  /// Whether something holds the window the tour must not talk over: a sheet — Full Disk Access
  /// first, at launch — or Open Quickly.
  var isTourHeldBack: Bool {
    permissions?.isPresentingStep == true || pendingRestart != nil || pendingSwitch != nil
      || diagnosticsExport != nil || hookConsentRequest != nil || quickOpen.isPresented
  }

  /// The step whose bubble points at `target` now, if any. Whether the window is the active one is
  /// the view's to say.
  func tourStep(on target: TourTarget) -> OnboardingStep? {
    guard case .loaded = state, !isTourHeldBack, let step = onboarding.step else { return nil }
    switch (step, target) {
    case (.newSession, .emptyStateNewSession), (.newSession, .toolbarNewSession):
      return isPresentingNewSession ? nil : step
    case (.statuses, .sessionRow(let id)), (.finale, .sessionRow(let id)):
      return id == onboarding.sessionID && !isPresentingNewSession ? step : nil
    default:
      return isPresentingNewSession && step.draftTarget == target ? step : nil
    }
  }

  /// The bubble of a step outside the draft, which knows nothing of the draft.
  func tourBubble(for step: OnboardingStep) -> OnboardingModel.Bubble {
    let waits =
      onboarding.sessionID.flatMap { id in sessions.first { $0.id == id } }?
      .taskStatus == .todo
    return OnboardingModel.bubble(for: step, waitsInToDo: waits)
  }

  /// Settings › Show Tutorial Again: from the first bubble, or from the draft if one is on screen,
  /// with the window brought forward to show it.
  public func replayTutorial() {
    onboarding.send(.replay)
    if isPresentingNewSession { onboarding.send(.draftOpened) }
    showWorkspaceWindow?()
  }
}
