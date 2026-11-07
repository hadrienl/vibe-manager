import CompanionCore
import Foundation
import Testing

private let request = RemoteNewSession(
  name: "", folder: "/f", agentID: "a", modelID: nil, prompt: "Bonjour", start: true,
  coordinates: false)

@Test("The Mac's answer ends the creation shown")
func creationAnswered() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  #expect(creation.created("S") == .created("S"))
  #expect(creation.pending == nil)
  #expect(creation.created("S") == nil)
}

@Test("A failure gives back all that was asked; one about something else is not the creation's")
func creationFailed() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  #expect(creation.failed(.messageNotSent) == nil)
  #expect(creation.pending == request)
  #expect(creation.failed(.folderMissing) == .failed(request, .folderMissing))
  #expect(creation.pending == nil)
  #expect(creation.failed(.other("Non")) == nil)
}

@Test("A session made after the delay is shown once, even when asked again meanwhile")
func creationLate() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  #expect(creation.expire() == request)
  #expect(creation.expire() == nil)
  #expect(creation.created("S") == .created("S"))

  #expect(creation.submit(request) == true)
  #expect(creation.expire() == request)
  // Held back, never written: the late answer settles it.
  #expect(creation.submit(request) == false)
  #expect(creation.created("S") == .created("S"))
  #expect(creation.pending == nil)
}

@Test("A late failure lets the request held back go, and is otherwise already told")
func creationLateFailure() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  _ = creation.expire()
  #expect(creation.submit(request) == false)
  #expect(creation.failed(.noAgent) == .send(request))
  #expect(creation.pending == request)
  #expect(creation.created("S") == .created("S"))

  #expect(creation.submit(request) == true)
  _ = creation.expire()
  #expect(creation.failed(.noAgent) == .ignored)
}

@Test("A lost connection will never answer: nothing is held back any more")
func creationConnectionLost() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  _ = creation.expire()
  creation.connectionLost()
  #expect(creation.created("S") == nil)
  #expect(creation.submit(request) == true)
}

@Test("A request the old connection took is not waited for on the new one")
func creationExpiredAfterConnectionLost() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  creation.connectionLost()
  #expect(creation.expire() == request)
  #expect(creation.submit(request) == true)
}

@Test("A second tap makes no second request")
func creationSubmittedTwice() {
  var creation = RemoteCreation()
  let other = RemoteNewSession(
    name: "", folder: "/g", agentID: "a", modelID: nil, prompt: "", start: true, coordinates: false)
  #expect(creation.submit(request) == true)
  #expect(creation.submit(other) == false)
  #expect(creation.pending == request)
}

@Test("A different request held back goes once the one given up on exists")
func creationHeldDifferent() {
  var creation = RemoteCreation()
  let other = RemoteNewSession(
    name: "", folder: "/g", agentID: "a", modelID: nil, prompt: "", start: true, coordinates: false)
  #expect(creation.submit(request) == true)
  _ = creation.expire()
  #expect(creation.submit(other) == false)
  #expect(creation.created("S") == .send(other))
  #expect(creation.pending == other)
  #expect(creation.created("T") == .created("T"))
}

private func session(
  _ id: String, named name: String, coordinatorID: String? = nil, isCoordinator: Bool = false
) -> RemoteSession {
  RemoteSession(
    id: id, name: name, folderPath: "/f", folderName: "f", agentName: "Claude", status: .doing,
    activity: .working, appearance: RemoteAppearance(symbol: "star", color: "#FFFFFF"),
    coordinatorID: coordinatorID, isCoordinator: isCoordinator, updatedAt: .now)
}

@Test("A session made while the connection was lost is found in the Mac's next list")
func creationFoundInList() {
  var creation = RemoteCreation()
  let old = session("A", named: "Bonjour")
  #expect(creation.submit(request, listed: [old]) == true)
  // On a live connection, only the Mac's answer counts.
  #expect(creation.listed([old, session("S", named: "Bonjour")]) == nil)
  creation.connectionLost()
  #expect(creation.isUnanswered)
  #expect(creation.listed([old]) == nil)
  #expect(creation.pending == request)
  // Another name, a coordinator's child, a coordinator: not what was asked.
  #expect(
    creation.listed([
      old, session("B", named: "Autre"), session("C", named: "Bonjour", coordinatorID: "A"),
      session("D", named: "Bonjour", isCoordinator: true),
    ]) == nil)
  #expect(creation.listed([old, session("S", named: "Bonjour")]) == .created("S"))
  #expect(creation.pending == nil)
  #expect(creation.listed([old, session("S", named: "Bonjour")]) == nil)
}

@Test("A request perhaps made says so when it expires, and is still found after")
func creationUnansweredExpires() {
  var creation = RemoteCreation()
  #expect(creation.submit(request, listed: [session("A", named: "x")]) == true)
  #expect(!creation.isUnanswered)
  creation.connectionLost()
  #expect(creation.isUnanswered)
  #expect(creation.expire() == request)
  #expect(!creation.isUnanswered)
  #expect(
    creation.listed([session("A", named: "x"), session("S", named: "Bonjour")]) == .created("S"))
  #expect(creation.submit(request) == true)
}

@Test("The session is named as the Mac names it: the name typed, the message, else the folder")
func creationNamedAsTheMacDoes() {
  func found(_ asked: RemoteNewSession, as name: String) -> Bool {
    var creation = RemoteCreation()
    _ = creation.submit(asked, listed: [session("A", named: "x")])
    creation.connectionLost()
    return creation.listed([session("A", named: "x"), session("S", named: name)]) != nil
  }
  func asked(name: String = "", prompt: String = "") -> RemoteNewSession {
    RemoteNewSession(
      name: name, folder: "/Users/me/projet", agentID: "a", modelID: nil, prompt: prompt,
      start: true, coordinates: false)
  }
  #expect(found(asked(name: "  Ma\tsession \n"), as: "Ma session"))
  #expect(found(asked(prompt: "\n  Corrige le bug  \nensuite"), as: "Corrige le bug"))
  #expect(
    found(asked(prompt: String(repeating: "a", count: 80)), as: String(repeating: "a", count: 60)))
  #expect(found(asked(), as: "projet"))
  #expect(!found(asked(name: "Autre"), as: "projet"))
}

@Test("Another Mac's list is no answer")
func creationOtherMacList() {
  var creation = RemoteCreation()
  #expect(creation.submit(request, listed: [session("A", named: "x")]) == true)
  creation.connectionLost()
  #expect(creation.listed([session("Z", named: "x"), session("S", named: "Bonjour")]) == nil)
  #expect(
    creation.listed([session("A", named: "x"), session("S", named: "Bonjour")]) == .created("S"))
}

@Test("A different request held back goes once the one lost is found")
func creationHeldBehindLost() {
  var creation = RemoteCreation()
  let other = RemoteNewSession(
    name: "Autre", folder: "/g", agentID: "a", modelID: nil, prompt: "", start: true,
    coordinates: false)
  #expect(creation.submit(request, listed: [session("A", named: "x")]) == true)
  _ = creation.expire()
  #expect(creation.submit(other) == false)
  creation.connectionLost()
  #expect(
    creation.listed([session("A", named: "x"), session("S", named: "Bonjour")]) == .send(other))
  #expect(creation.pending == other)
  #expect(creation.created("T") == .created("T"))
}

@Test("A Mac that never answers does not hold requests back for ever")
func creationHoldEnds() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  _ = creation.expire()
  #expect(creation.submit(request) == false)
  #expect(creation.expire() == request)
  #expect(creation.submit(request) == true)
}

@Test("A creation back on the waiting screen shows; elsewhere it waits for New Session, once")
func creationReturnedElsewhere() {
  var creation = RemoteCreation()
  let returned = ReturnedCreation(request: request, error: "Non")
  #expect(creation.returned(returned, isWaiting: true) == returned)
  #expect(creation.takeKept() == nil)
  #expect(creation.returned(returned, isWaiting: false) == nil)
  #expect(creation.takeKept() == returned)
  #expect(creation.takeKept() == nil)
}

@Test("A creation kept is forgotten once another is asked, or once the session turns up")
func creationKeptForgotten() {
  var creation = RemoteCreation()
  let returned = ReturnedCreation(request: request, error: "Non")
  _ = creation.returned(returned, isWaiting: false)
  #expect(creation.submit(request) == true)
  #expect(creation.takeKept() == nil)

  #expect(creation.created("S") == .created("S"))
  #expect(creation.submit(request, listed: [session("A", named: "x")]) == true)
  creation.connectionLost()
  _ = creation.expire()
  _ = creation.returned(returned, isWaiting: false)
  #expect(
    creation.listed([session("A", named: "x"), session("S", named: "Bonjour")]) == .created("S"))
  #expect(creation.takeKept() == nil)
}
