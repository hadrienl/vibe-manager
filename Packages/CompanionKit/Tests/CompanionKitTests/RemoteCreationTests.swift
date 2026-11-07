import CompanionCore
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

@Test("A Mac that never answers does not hold requests back for ever")
func creationHoldEnds() {
  var creation = RemoteCreation()
  #expect(creation.submit(request) == true)
  _ = creation.expire()
  #expect(creation.submit(request) == false)
  #expect(creation.expire() == request)
  #expect(creation.submit(request) == true)
}
