import Foundation
import Testing
import VibeApplication
import VibeComposition
import VibeDomain

@testable import VibeUI

/// #45 on the application composed for real: the mock agent reports through the same log the
/// hooks of a real CLI write to, in a real terminal, read by the real tracker.
@MainActor
@Suite("Agent activity", .serialized, .timeLimit(.minutes(3)))
struct AgentActivityScenarioTests {
  @Test(
    "An answer finished out of sight is unread until shown, and a question holds until answered")
  func unreadAndQuestion() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    let model = environment.appModel
    await model.load()
    let folder = try scenario.folder("work")

    let first = try await scenario.create(in: environment, name: "First", folder: folder)
    let second = try await scenario.create(in: environment, name: "Second", folder: folder)
    model.select(second)
    #expect(await eventually { model.activity(for: first)?.source == .structured })

    // A turn of the first session, while the second is on screen.
    await scenario.type("hello\r", into: first, in: environment)
    #expect(await eventually { model.activity(for: first)?.unreadSince != nil })
    let unread = SessionStatusPresentation.make(
      session: try #require(scenario.stored(first, in: environment)),
      paneStatus: scenario.pane(first, in: environment)?.status,
      activity: model.activity(for: first))
    #expect(unread.needsAttention)

    // Shown, it is read.
    model.select(first)
    #expect(await eventually { model.activity(for: first)?.unreadSince == nil })

    // A permission, which holds while the session is on screen, until its key is typed.
    await scenario.type("event:PermissionRequest\r", into: first, in: environment)
    #expect(await eventually { model.activity(for: first)?.activity == .awaitingUser(.approval) })
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.activity(for: first)?.activity == .awaitingUser(.approval))
    await scenario.type("\r", into: first, in: environment)
    #expect(await eventually { model.activity(for: first)?.activity != .awaitingUser(.approval) })

    // A turn that ends on the session in front of the user is not unread.
    await scenario.type("again\r", into: first, in: environment)
    #expect(await eventually { model.activity(for: first)?.activity == .idle })
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.activity(for: first)?.unreadSince == nil)

    // Unread again, then quit: the mark is on disk for the next launch.
    model.select(second)
    await scenario.type("later\r", into: first, in: environment)
    #expect(await eventually { model.activity(for: first)?.unreadSince != nil })
    await environment.shutdown(keepingAgentsRunning: false)
    let document = try String(
      contentsOf: scenario.data.appendingPathComponent("agent-activity.json"), encoding: .utf8)
    #expect(document.contains(first.rawValue.uuidString))
    #expect(document.contains("unreadSince"))

    await scenario.tearDown()
  }
}
