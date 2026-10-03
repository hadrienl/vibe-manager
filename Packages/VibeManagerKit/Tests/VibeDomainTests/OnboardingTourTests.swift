import Foundation
import Testing

@testable import VibeDomain

@Suite("The first launch's tour")
struct OnboardingTourTests {
  private let session = SessionID()

  private func walked(_ events: [OnboardingEvent], from tour: OnboardingTour) -> OnboardingTour {
    events.reduce(tour) { $0.applying($1) }
  }

  @Test("Walked to the end on the user's own gestures, the session made in To Do")
  func walkedThroughToDo() {
    var tour = OnboardingTour.step(.newSession, session: nil)
    tour = tour.applying(.draftOpened)
    #expect(tour == .step(.name, session: nil))
    tour = tour.applying(.nameCommitted)
    #expect(tour == .step(.folder, session: nil))
    tour = tour.applying(.folderChosen)
    #expect(tour == .step(.options, session: nil))
    tour = tour.applying(.promptTyped)
    #expect(tour == .step(.prompt, session: nil))
    tour = tour.applying(.created(session, launched: false))
    #expect(tour == .step(.statuses, session: session))
    tour = tour.applying(.taskStatusChanged(session, .doing))
    #expect(tour == .step(.finale, session: session))
    tour = tour.applying(.next)
    #expect(tour == .finished)
  }

  @Test("Next goes on where no gesture is required, and a launched session needs no move")
  func walkedWithNext() {
    let tour = walked(
      [.draftOpened, .next, .next, .next, .created(session, launched: true), .next, .next],
      from: .step(.newSession, session: nil))
    #expect(tour == .finished)
  }

  @Test("Creating before the last bubble skips to the statuses")
  func createdEarly() {
    for step in [OnboardingStep.name, .folder, .options] {
      #expect(
        OnboardingTour.step(step, session: nil).applying(.created(session, launched: true))
          == .step(.statuses, session: session))
    }
  }

  @Test("A draft discarded sends the tour back to New Session")
  func discardedDraft() {
    for step in [OnboardingStep.name, .folder, .options, .prompt] {
      #expect(
        OnboardingTour.step(step, session: nil).applying(.draftDiscarded)
          == .step(.newSession, session: nil))
    }
  }

  @Test("Skip ends the tour from every step")
  func skipFromEverywhere() {
    for step in OnboardingStep.allCases {
      #expect(OnboardingTour.step(step, session: session).applying(.skip) == .finished)
    }
    #expect(OnboardingTour.notStarted.applying(.skip) == .notStarted)
  }

  @Test("Replay starts over, whatever came before")
  func replay() {
    for tour in [OnboardingTour.notStarted, .finished, .step(.finale, session: session)] {
      #expect(tour.applying(.replay) == .step(.newSession, session: nil))
    }
  }

  @Test("An event the step does not wait for changes nothing")
  func unrelatedEvents() {
    let other = SessionID()
    let cases: [(OnboardingTour, OnboardingEvent)] = [
      (.step(.newSession, session: nil), .next),
      (.step(.newSession, session: nil), .folderChosen),
      (.step(.name, session: nil), .folderChosen),
      (.step(.name, session: nil), .draftOpened),
      (.step(.folder, session: nil), .nameCommitted),
      (.step(.prompt, session: nil), .next),
      (.step(.statuses, session: session), .taskStatusChanged(other, .doing)),
      (.step(.statuses, session: session), .taskStatusChanged(session, .waiting)),
      (.step(.statuses, session: session), .draftDiscarded),
      (.step(.finale, session: session), .taskStatusChanged(session, .done)),
      (.finished, .draftOpened),
      (.notStarted, .draftOpened),
    ]
    for (tour, event) in cases {
      #expect(tour.applying(event) == tour, "\(event) at \(tour)")
    }
  }

  @Test("At launch: a first install starts, an update with sessions never sees the tour")
  func resumedFirstLaunch() {
    #expect(
      OnboardingTour.notStarted.resumed(hasSessions: false) { _ in false }
        == .step(.newSession, session: nil))
    #expect(OnboardingTour.notStarted.resumed(hasSessions: true) { _ in true } == .finished)
    #expect(OnboardingTour.finished.resumed(hasSessions: false) { _ in false } == .finished)
  }

  @Test("At launch: back where it was, or at New Session when that is gone")
  func resumedMidway() {
    for step in [OnboardingStep.name, .folder, .options, .prompt] {
      #expect(
        OnboardingTour.step(step, session: nil).resumed(hasSessions: true) { _ in true }
          == .step(.newSession, session: nil))
    }
    let statuses = OnboardingTour.step(.statuses, session: session)
    #expect(statuses.resumed(hasSessions: true) { $0 == session } == statuses)
    #expect(
      statuses.resumed(hasSessions: true) { _ in false } == .step(.newSession, session: nil))
    let finale = OnboardingTour.step(.finale, session: session)
    #expect(finale.resumed(hasSessions: true) { $0 == session } == finale)
    #expect(
      OnboardingTour.step(.statuses, session: nil).resumed(hasSessions: true) { _ in true }
        == .step(.newSession, session: nil))
    #expect(
      OnboardingTour.step(.newSession, session: nil).resumed(hasSessions: true) { _ in true }
        == .step(.newSession, session: nil))
  }

  @Test("Kept as it was written")
  func codable() throws {
    for tour in [
      OnboardingTour.notStarted, .finished, .step(.name, session: nil),
      .step(.statuses, session: session),
    ] {
      let data = try JSONEncoder().encode(tour)
      #expect(try JSONDecoder().decode(OnboardingTour.self, from: data) == tour)
    }
  }

  @Test("Six counted steps, and a closing bubble outside the count")
  func numbering() {
    #expect(OnboardingStep.counted.count == 6)
    #expect(OnboardingStep.newSession.number == 1)
    #expect(OnboardingStep.statuses.number == 6)
    #expect(OnboardingStep.finale.number == nil)
  }
}
