import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

private let idleScript = """
  i=0
  while [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  """

@Test("The supervisor refuses to start a second terminal for a live session")
func refusesConcurrentSessionsForTheSameIdentifier() async throws {
  let supervisor = PTYTerminalSupervisor()
  let id = SessionID()
  _ = try await supervisor.start(TerminalTestSupport.spec(script: idleScript), for: id)

  await #expect(throws: TerminalError.sessionAlreadyRunning(id)) {
    _ = try await supervisor.start(TerminalTestSupport.spec(script: idleScript), for: id)
  }

  await supervisor.stopAll(gracePeriod: .milliseconds(300))
}

@Test("A finished session can be restarted under the same identifier")
func restartsFinishedSession() async throws {
  let supervisor = PTYTerminalSupervisor()
  let id = SessionID()
  let first = try await supervisor.start(TerminalTestSupport.spec(script: "exit 0"), for: id)
  while await !first.state().isFinished {
    try await Task.sleep(for: .milliseconds(20))
  }

  let second = try await supervisor.start(TerminalTestSupport.spec(script: idleScript), for: id)

  #expect(await supervisor.session(for: id) != nil)
  await second.stop(gracePeriod: .milliseconds(300))
}

@Test("Stopping all sessions leaves no process behind")
func stopAllTerminatesEveryProcess() async throws {
  let supervisor = PTYTerminalSupervisor()
  var identifiers: [Int32] = []

  for _ in 0..<3 {
    let session = try await supervisor.start(
      TerminalTestSupport.spec(script: idleScript),
      for: SessionID()
    )
    guard case .running(let processIdentifier) = await session.state() else {
      // The session may still be starting; wait for the running state.
      var state = await session.state()
      while case .starting = state {
        try await Task.sleep(for: .milliseconds(20))
        state = await session.state()
      }
      if case .running(let processIdentifier) = state {
        identifiers.append(processIdentifier)
      }
      continue
    }
    identifiers.append(processIdentifier)
  }

  #expect(identifiers.count == 3)
  await supervisor.stopAll(gracePeriod: .milliseconds(300))
  try await Task.sleep(for: .milliseconds(300))

  for identifier in identifiers {
    #expect(!isProcessAlive(identifier))
  }
  #expect(await supervisor.session(for: SessionID()) == nil)
}
