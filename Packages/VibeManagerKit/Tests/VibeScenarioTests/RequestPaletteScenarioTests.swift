import Foundation
import Testing
import VibeApplication
import VibeComposition
import VibeDomain

@testable import VibeUI

/// #40 on the application composed for real: the mock agent asks through the same log a real
/// CLI's hooks write to, and the answer given from the palette is typed into its own terminal.
@MainActor
@Suite("Requests of background sessions", .serialized, .timeLimit(.minutes(3)))
struct RequestPaletteScenarioTests {
  private static let permission =
    #"event:PermissionRequest {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make release"}}"#

  @Test("A background request reaches the palette, and its answer only its own terminal")
  func answeredFromThePalette() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    let model = environment.appModel
    await model.load()
    let folder = try scenario.folder("work")

    let background = try await scenario.create(in: environment, name: "Background", folder: folder)
    let front = try await scenario.create(in: environment, name: "Front", folder: folder)
    model.select(front)
    #expect(await eventually { model.activity(for: background)?.source == .structured })
    #expect(await eventually { await scenario.output(front, in: environment).contains("Holding.") })

    // Asked in the background: in the palette in well under a second.
    await scenario.type(Self.permission + "\r", into: background, in: environment)
    let asked = ContinuousClock.now
    #expect(
      await eventually {
        model.pendingRequests.first?.answering.answers.contains(.allowOnce) == true
      })
    #expect(ContinuousClock.now - asked < .seconds(1))
    let pending = try #require(model.pendingRequests.first)
    #expect(pending.session.id == background)
    #expect(RequestPresentation.subject(of: pending.request.content) == "make release")

    // Answered from the palette: typed into the background session, which reports the tool done.
    await model.answer(.allowOnce, to: pending.id)
    #expect(
      await eventually { await scenario.output(background, in: environment).contains("answer: y") })
    #expect(await eventually { model.pendingRequests.isEmpty })
    #expect(model.requestOutcome?.outcome == .sent)

    // The session in front was neither changed nor sent anything.
    #expect(model.selectedSessionID == front)
    let frontOutput = await scenario.output(front, in: environment)
    #expect(!frontOutput.contains("answer:"))
    #expect(!frontOutput.contains("echo:"))

    // A request answered in its own terminal leaves the palette too.
    await scenario.type(Self.permission + "\r", into: background, in: environment)
    #expect(await eventually { !model.pendingRequests.isEmpty })
    await scenario.type("n\r", into: background, in: environment)
    #expect(await eventually { model.pendingRequests.isEmpty })

    // A session that stops takes its requests with it.
    await scenario.type(Self.permission + "\r", into: background, in: environment)
    #expect(await eventually { !model.pendingRequests.isEmpty })
    await scenario.pane(background, in: environment)?.stop()
    #expect(await eventually { model.pendingRequests.isEmpty })

    await environment.shutdown(keepingAgentsRunning: false)
    await scenario.tearDown()
  }
}
