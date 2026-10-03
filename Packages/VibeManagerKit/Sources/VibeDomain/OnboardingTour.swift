import Foundation

/// The bubbles of the first launch (#338), from the empty window to a first session started.
///
/// Counted steps first, in the order they are walked; the closing bubble is not counted.
public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
  /// New Session, in the empty window or in the toolbar.
  case newSession
  /// The draft's name.
  case name
  /// The draft's working folder.
  case folder
  /// The agent, its model, the appearance and More Options, at once.
  case options
  /// The prompt, and Add to To Do under it.
  case prompt
  /// The new session's row: how its status changes, and, when it waits in To Do, the invitation
  /// to move it In Progress.
  case statuses
  /// Done: a word of encouragement, and the tour is over.
  case finale

  /// The steps the indicator counts.
  public static let counted: [OnboardingStep] = [
    .newSession, .name, .folder, .options, .prompt, .statuses,
  ]

  /// Where the step stands in the indicator, from 1. `nil` for the closing bubble.
  public var number: Int? {
    Self.counted.firstIndex(of: self).map { $0 + 1 }
  }

  /// Whether the step lives in the new session's draft, which is not kept across launches.
  public var isInDraft: Bool {
    switch self {
    case .name, .folder, .options, .prompt: true
    case .newSession, .statuses, .finale: false
    }
  }
}

/// What the user did that the tour may be waiting for.
public enum OnboardingEvent: Equatable, Sendable {
  case draftOpened
  /// The draft went without becoming a session: discarded, or left empty for another session.
  case draftDiscarded
  /// The name field was left with a name in it.
  case nameCommitted
  case folderChosen
  case promptTyped
  /// A session was made; `launched` when its agent was started at once rather than left in To Do.
  case created(SessionID, launched: Bool)
  case taskStatusChanged(SessionID, SessionTaskStatus)
  /// Next, or Done on the closing bubble.
  case next
  case skip
  /// Settings › Show Tutorial Again.
  case replay
}

/// Where the user is in the tour, as it is kept across launches.
///
/// A pure value: what the user does is folded into it with `applying(_:)`, and what a launch finds
/// is reconciled with `resumed(hasSessions:contains:)`. An event the current step does not wait
/// for changes nothing.
public enum OnboardingTour: Equatable, Codable, Sendable {
  /// Never shown: a first launch, or an installation that predates the tour.
  case notStarted
  /// `session` is the session the tour made, from `statuses` on.
  case step(OnboardingStep, session: SessionID?)
  /// Walked to the end, or skipped. Only Show Tutorial Again brings it back.
  case finished

  public var step: OnboardingStep? {
    if case .step(let step, _) = self { return step }
    return nil
  }

  public var sessionID: SessionID? {
    if case .step(_, let session) = self { return session }
    return nil
  }

  public func applying(_ event: OnboardingEvent) -> OnboardingTour {
    switch event {
    case .replay:
      return .step(.newSession, session: nil)
    case .skip:
      return self == .notStarted ? self : .finished
    default:
      break
    }
    guard case .step(let step, let session) = self else { return self }
    switch (step, event) {
    case (.newSession, .draftOpened):
      return .step(.name, session: nil)
    // Return in a field, or a template, can create before the last bubble: the tour follows.
    case (.newSession, .created(let id, _)), (.name, .created(let id, _)),
      (.folder, .created(let id, _)), (.options, .created(let id, _)),
      (.prompt, .created(let id, _)):
      return .step(.statuses, session: id)
    case (.name, .draftDiscarded), (.folder, .draftDiscarded), (.options, .draftDiscarded),
      (.prompt, .draftDiscarded):
      return .step(.newSession, session: nil)
    case (.name, .nameCommitted), (.name, .next):
      return .step(.folder, session: nil)
    case (.folder, .folderChosen), (.folder, .next):
      return .step(.options, session: nil)
    case (.options, .promptTyped), (.options, .next):
      return .step(.prompt, session: nil)
    case (.statuses, .taskStatusChanged(let id, .doing)) where id == session:
      return .step(.finale, session: session)
    case (.statuses, .next):
      return .step(.finale, session: session)
    case (.finale, .next):
      return .finished
    default:
      return self
    }
  }

  /// What a launch makes of the tour it finds.
  ///
  /// - Parameters:
  ///   - hasSessions: whether the store holds any session, archived ones included.
  ///   - contains: whether a session is still there and not archived.
  public func resumed(hasSessions: Bool, contains: (SessionID) -> Bool) -> OnboardingTour {
    switch self {
    case .notStarted:
      // An update from a version without the tour: its user knows their way already.
      return hasSessions ? .finished : .step(.newSession, session: nil)
    case .finished:
      return self
    case .step(let step, let session):
      // The draft is not kept across launches, and a session gone leaves nothing to point at.
      if step.isInDraft { return .step(.newSession, session: nil) }
      if let session, !contains(session) { return .step(.newSession, session: nil) }
      if step != .newSession, session == nil { return .step(.newSession, session: nil) }
      return self
    }
  }
}
