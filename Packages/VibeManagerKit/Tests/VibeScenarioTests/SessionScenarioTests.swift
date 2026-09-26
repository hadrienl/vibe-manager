import Darwin
import Foundation
import Testing
import VibeAgents
import VibeApplication
import VibeComposition
import VibeDomain
import VibeTerminal

@testable import VibeUI

/// The journeys of the ticket, on the application composed for real: file store, runtime document,
/// a terminal host in a process of its own, and the mock agents in real terminals.
@MainActor
@Suite("Scenarios", .serialized, .timeLimit(.minutes(3)))
struct SessionScenarioTests {
  @Test("Creation: a draft becomes a stored, running session whose resume identifier is kept")
  func creation() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold", "--session-id", "scenario-one"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")

    let id = try await scenario.create(
      in: environment, name: "First", prompt: "Say hello", folder: folder)

    #expect(scenario.stored(id, in: environment)?.status == .active)
    #expect(await scenario.processIdentifier(id, in: environment) != nil)
    #expect(scenario.pane(id, in: environment)?.session is HostedTerminalSession)
    #expect(
      await eventually { await scenario.output(id, in: environment).contains("prompt: Say hello") })
    #expect(
      await eventually {
        await environment.appModel.reload()
        return scenario.stored(id, in: environment)?.agent?.resumeIdentifier == "scenario-one"
      })
    #expect(!ProcessTree.snapshot(under: scenario.root).isEmpty)

    await scenario.tearDown()
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
  }

  @Test("Parallel sessions: three agents, two of them flooding, all answer every keystroke")
  func parallelSessions() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(
      behaviour: ["--hold", "--flood", "2048"], secondary: ["--hold"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")
    let flooding = [
      try await scenario.create(in: environment, name: "Flood one", folder: folder),
      try await scenario.create(in: environment, name: "Flood two", folder: folder),
    ]
    let visible = try await scenario.create(
      in: environment, name: "Visible", provider: "mock-b", folder: folder)
    environment.appModel.select(visible)
    let sessions = flooding + [visible]

    var latencies: [Duration] = []
    for round in 1...10 {
      for id in sessions {
        let session = try #require(scenario.pane(id, in: environment)?.session)
        let echo = EchoWatch(
          session: session, expecting: "echo: ping-\(round)-\(id.rawValue.uuidString.prefix(4))")
        let started = ContinuousClock.now
        await scenario.type(
          "ping-\(round)-\(id.rawValue.uuidString.prefix(4))\r", into: id, in: environment)
        #expect(await echo.arrived(within: .seconds(10)), "session \(id), round \(round)")
        latencies.append(ContinuousClock.now - started)
      }
    }
    // The budget itself is measured by the performance tests: here, nothing is lost, and nothing
    // takes long enough to be noticed.
    let sorted = latencies.sorted()
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    #expect(p95 < .seconds(1), "p95 \(p95)")

    await scenario.tearDown()
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
  }

  @Test("Closing: a session closes, and one that ignores SIGTERM is killed with its child")
  func closing() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(
      behaviour: ["--hold"], secondary: ["--hold", "--ignore-sigterm", "--spawn-child"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")
    let polite = try await scenario.create(in: environment, name: "Polite", folder: folder)
    let stubborn = try await scenario.create(
      in: environment, name: "Stubborn", provider: "mock-b", folder: folder)
    #expect(
      await eventually { await scenario.output(stubborn, in: environment).contains("mock-child:") })
    #expect(ProcessTree.snapshot(under: scenario.root).count >= 3)

    await environment.appModel.close(polite)
    await environment.appModel.close(stubborn)

    #expect(scenario.stored(polite, in: environment)?.status == .closed)
    #expect(scenario.stored(stubborn, in: environment)?.status == .closed)
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
    await scenario.tearDown()
  }

  @Test("Resuming: after Stop All, the next launch resumes each agent natively, where it was")
  func resumeAfterQuit() async throws {
    let scenario = try Scenario()
    let first = try scenario.compose(behaviour: ["--hold", "--session-id", "resume-me"])
    await first.appModel.load()
    let folder = try scenario.folder("work")
    let id = try await scenario.create(in: first, name: "Resumable", folder: folder)
    #expect(
      await eventually {
        await first.appModel.reload()
        return scenario.stored(id, in: first)?.agent?.resumeIdentifier == "resume-me"
      })

    await first.shutdown(keepingAgentsRunning: false)
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })

    let second = try scenario.compose(behaviour: ["--hold"])
    await second.appModel.load()

    #expect(second.appModel.previousShutdownVerdict == "clean")
    #expect(await eventually { scenario.stored(id, in: second)?.status == .active })
    #expect(
      await eventually { await scenario.output(id, in: second).contains("Resuming mock session.") })
    let resumed = try #require(scenario.stored(id, in: second))
    #expect(resumed.agent?.providerID == "mock")
    #expect(resumed.agent?.resumeIdentifier == "resume-me")
    #expect(await scenario.output(id, in: second).contains("cwd: \(folder)"))
    await scenario.tearDown()
  }

  @Test("Resuming a detached run: the agents kept running are taken back, history and all")
  func resumeDetached() async throws {
    let scenario = try Scenario()
    let first = try scenario.compose(behaviour: ["--hold"])
    await first.appModel.load()
    let folder = try scenario.folder("work")
    let id = try await scenario.create(
      in: first, name: "Kept", prompt: "before quitting", folder: folder)
    #expect(
      await eventually { await scenario.output(id, in: first).contains("prompt: before quitting") })
    let agent = try #require(await scenario.processIdentifier(id, in: first))

    await first.shutdown(keepingAgentsRunning: true)
    #expect(isAlive(agent))

    let second = try scenario.compose(behaviour: ["--hold"])
    await second.appModel.load()

    #expect(second.appModel.previousShutdownVerdict == "detached")
    #expect(await eventually { await scenario.processIdentifier(id, in: second) == agent })
    #expect(
      await eventually { await scenario.output(id, in: second).contains("prompt: before quitting") }
    )
    // The agent it took back still answers.
    await scenario.type("still-there\r", into: id, in: second)
    #expect(
      await eventually { await scenario.output(id, in: second).contains("echo: still-there") })
    await scenario.tearDown()
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
  }

  @Test("Recent folders: the last folder is proposed again, and the others kept, after a relaunch")
  func recentFolders() async throws {
    let scenario = try Scenario()
    let first = try scenario.compose(behaviour: ["--hold"])
    await first.appModel.load()
    let api = try scenario.folder("api")
    let web = try scenario.folder("web")
    try await scenario.create(in: first, name: "API", folder: api)
    try await scenario.create(in: first, name: "Web", folder: web)
    await first.shutdown(keepingAgentsRunning: false)

    let second = try scenario.compose(behaviour: ["--hold"])
    await second.appModel.load()
    second.appModel.beginNewSession()
    let sheet = try #require(second.appModel.newSessionModel)
    await sheet.load()

    #expect(sheet.draft.workingDirectoryPath == web)
    #expect(sheet.recentFolders.map(\.folder.path) == [web, api])
    #expect(sheet.recentFolders.allSatisfy { $0.availability == .available })
    second.appModel.cancelNewSession()
    await scenario.tearDown()
  }

  @Test("A crash: the sessions are offered at the next launch, and nothing is relaunched unasked")
  func crash() async throws {
    let scenario = try Scenario()
    let first = try scenario.compose(behaviour: ["--hold"])
    await first.appModel.load()
    let folder = try scenario.folder("work")
    let id = try await scenario.create(in: first, name: "Crashed", folder: folder)
    // What a crash leaves on disk: the store and the runtime document as they are while it runs.
    let store = scenario.data.appendingPathComponent("sessions.json")
    let runtime = scenario.data.appendingPathComponent("runtime.json")
    #expect(await eventually { (try? Data(contentsOf: runtime))?.isEmpty == false })
    let storeBytes = try Data(contentsOf: store)
    var runtimeDocument = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as? [String: Any])
    await first.shutdown(keepingAgentsRunning: false)
    // The process that wrote it is gone: a pid no process has any more.
    var state = try #require(runtimeDocument["state"] as? [String: Any])
    #expect(state["phase"] as? String == "running")
    state["processIdentifier"] = try await Self.deadProcessIdentifier()
    runtimeDocument["state"] = state
    try storeBytes.write(to: store)
    try JSONSerialization.data(withJSONObject: runtimeDocument).write(to: runtime)

    let second = try scenario.compose(behaviour: ["--hold"])
    await second.appModel.load()

    #expect(second.appModel.previousShutdownVerdict == "unexpected")
    #expect(second.appModel.restoreOffer?.sessionCount == 1)
    #expect(scenario.stored(id, in: second)?.status == .closed)
    #expect(ProcessTree.snapshot(under: scenario.root).isEmpty)
    await scenario.tearDown()
  }

  @Test("Archiving: an archived session cannot run; unarchived, it comes back closed and restarts")
  func archiving() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")
    let id = try await scenario.create(in: environment, name: "Archived", folder: folder)
    await environment.appModel.close(id)

    await environment.appModel.archive(id)
    let archived = try #require(scenario.stored(id, in: environment))
    #expect(archived.status == .archived)
    #expect(!environment.appModel.canRestart(archived))

    await environment.appModel.restore(id)
    let restored = try #require(scenario.stored(id, in: environment))
    #expect(restored.status == .closed)
    #expect(environment.appModel.canRestart(restored))

    await environment.appModel.restart(id)
    // Without a conversation to resume, a restart shows the summary it will send first.
    if let pending = environment.appModel.pendingRestart {
      await environment.appModel.confirmRestart(pending.briefText)
    }
    #expect(await eventually { scenario.stored(id, in: environment)?.status == .active })
    #expect(await scenario.processIdentifier(id, in: environment) != nil)
    await scenario.tearDown()
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
  }

  @Test("Switching agent: mock to mock-b, with a summary, recorded in the session's history")
  func switchingAgent() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"], secondary: ["--hold"])
    await environment.appModel.load()
    let folder = try scenario.folder("work")
    let id = try await scenario.create(
      in: environment, name: "Switched", prompt: "Refactor the parser", folder: folder)
    let before = try #require(await scenario.processIdentifier(id, in: environment))

    environment.appModel.beginAgentSwitch(id, preselected: AgentTarget(providerID: "mock-b"))
    let sheet = try #require(environment.appModel.pendingSwitch)
    #expect(await eventually { sheet.canSwitch })
    #expect(sheet.handover == .summary)
    await environment.appModel.confirmAgentSwitch()

    let switched = try #require(scenario.stored(id, in: environment))
    #expect(switched.agent?.providerID == "mock-b")
    #expect(switched.agentHistory.count == 1)
    #expect(switched.agentHistory.first?.previous.providerID == "mock")
    #expect(await eventually { await scenario.processIdentifier(id, in: environment) != nil })
    #expect(await scenario.processIdentifier(id, in: environment) != before)
    #expect(!isAlive(before))
    await scenario.tearDown()
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
  }

  static func deadProcessIdentifier() async throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try task.run()
    task.waitUntilExit()
    return task.processIdentifier
  }
}

func isAlive(_ pid: pid_t) -> Bool {
  var info = proc_bsdinfo()
  let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
  return size > 0 && info.pbi_status != UInt32(SZOMB)
}

/// Watches a terminal for one line, from before the keystroke that should produce it.
final class EchoWatch: @unchecked Sendable {
  private let task: Task<Bool, Never>

  init(session: any TerminalSession, expecting text: String) {
    let ready = DispatchSemaphore(value: 0)
    // Detached: the caller waits for the attachment on its own thread, the main actor included.
    task = Task.detached {
      let attachment = await session.attach()
      ready.signal()
      var window = ""
      for await event in attachment.events {
        guard case .output(let bytes) = event else { continue }
        window += String(decoding: bytes, as: UTF8.self)
        if window.contains(text) { return true }
        // Only the tail can still hold a match that straddles two reads.
        if window.count > 4 * text.count + 64 { window = String(window.suffix(2 * text.count)) }
      }
      return false
    }
    ready.wait()
  }

  func arrived(within timeout: Duration) async -> Bool {
    let task = task
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      task.cancel()
      return first
    }
  }
}
