import Darwin
import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeTerminal

@testable import VibeUI

/// #237 on the application composed for real: the terminal host is the test fixture, in a process
/// of its own, killed here — never the user's.
@MainActor
@Suite("The terminal host stopped", .serialized, .timeLimit(.minutes(3)))
struct HostStoppedScenarioTests {
  @Test("The host killed: one message counts its sessions, and Restart All brings them back")
  func hostKilled() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    let model = environment.appModel
    let launcher = environment.launcher
    await model.load()
    let folder = try scenario.folder("work")
    let first = try await scenario.create(in: environment, name: "First", folder: folder)
    let second = try await scenario.create(in: environment, name: "Second", folder: folder)
    #expect(await eventually { launcher.isRunning(first) && launcher.isRunning(second) })
    #expect(model.sessionsStoppedWithHost.isEmpty)

    // Each agent has named its conversation: what it is resumed with once the host is back.
    #expect(
      await eventually {
        await model.reload()
        return scenario.stored(first, in: environment)?.agent?.resumeIdentifier != nil
          && scenario.stored(second, in: environment)?.agent?.resumeIdentifier != nil
      })
    let host = try #require(await environment.terminalSupervisor.hostIdentity())
    kill(host.processIdentifier, SIGKILL)

    #expect(
      await eventually { Set(model.sessionsStoppedWithHost) == [first, second] },
      "both sessions are counted, whether stopped or lost with the host")
    // Nothing restarted on its own, and neither counts as a conversation its agent refused.
    #expect(!launcher.isRunning(first) && !launcher.isRunning(second))
    #expect(model.resumeRefusals.isDisjoint(with: [first, second]))

    #expect(
      await eventually {
        scenario.stored(first, in: environment)?.status == .closed
          && scenario.stored(second, in: environment)?.status == .closed
      })
    await model.restartSessionsStoppedWithHost()
    if let confirmation = model.pendingBatch {
      await model.confirmBatch(confirmation)
    }
    #expect(await eventually { launcher.isRunning(first) && launcher.isRunning(second) })
    #expect(model.sessionsStoppedWithHost.isEmpty)
    await scenario.tearDown()
  }
}
