import Foundation
import Testing
import VibeApplication
import VibeBrowser
import VibeComposition
import VibeDomain
import VibeTerminal

@testable import VibeUI

/// #69 on the application composed for real: an agent in a real terminal, run by a real terminal
/// host, reaches its session's web view through `vibe`, the socket and the ancestry check.
@MainActor
@Suite("Web view", .serialized, .timeLimit(.minutes(3)))
struct WebViewScenarioTests {
  @Test("An agent opens a page in its own session's web view, and only there")
  func agentOpensPage() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    let model = environment.appModel
    await model.load()
    let folder = try scenario.folder("work")
    let page = URL(fileURLWithPath: folder).appendingPathComponent("index.html")
    try Data("<!doctype html><title>Scenario page</title><h1>Hello</h1>".utf8).write(to: page)

    let first = try await scenario.create(in: environment, name: "First", folder: folder)
    let second = try await scenario.create(in: environment, name: "Second", folder: folder)
    #expect(await eventually { await scenario.output(first, in: environment).contains("Holding.") })
    #expect(
      await eventually { await scenario.output(second, in: environment).contains("Holding.") })

    await scenario.type(
      "run:vibe browser open \(page.absoluteString)\r", into: first, in: environment)
    let browser = environment.browser.browser(for: first)
    #expect(await eventually { browser.tabs.first?.title == "Scenario page" })
    #expect(
      await eventually { await scenario.output(first, in: environment).contains("run-exit:") })
    let output = await scenario.output(first, in: environment)
    #expect(output.contains("run-exit: 0"), "\(output)")
    #expect(browser.tabs.first?.openedBy == .agent)
    #expect(browser.actionLog.records.contains { $0.tool == "tab_open" })

    // The other session's agent sees no tab of the first.
    await scenario.type("run:vibe browser list\r", into: second, in: environment)
    #expect(
      await eventually { await scenario.output(second, in: environment).contains("run-exit:") })
    let listed = await scenario.output(second, in: environment)
    #expect(listed.contains("[]"))
    #expect(!listed.contains("Scenario page"))
    #expect(environment.browser.browser(for: second).tabs.isEmpty)
    await scenario.tearDown()
  }

  @Test("A process outside every session's terminal is refused")
  func strangerRefused() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    await environment.appModel.load()
    let socket = TerminalHostLocation(dataDirectory: scenario.data).browserSocketPath
    #expect(FileManager.default.fileExists(atPath: socket))
    // Off the main actor: the command waits for an answer the application gives from there.
    let status = await Task.detached {
      BrowserCommandLine.run(
        ["browser", "list"], environment: [BrowserBridge.socketEnvironmentKey: socket],
        verifier: SameUserPeerVerifier())
    }.value
    #expect(status == 3)
    await scenario.tearDown()
  }

  @Test("A session's tabs come back after a relaunch, with the view as it was")
  func tabsSurviveRelaunch() async throws {
    let scenario = try Scenario()
    let environment = try scenario.compose(behaviour: ["--hold"])
    let model = environment.appModel
    await model.load()
    let folder = try scenario.folder("work")
    let id = try await scenario.create(in: environment, name: "Kept", folder: folder)
    environment.browser.open(URL(string: "http://localhost:9/a")!, in: id, openedBy: .user)
    await environment.shutdown(keepingAgentsRunning: false)

    let relaunched = try scenario.compose(behaviour: ["--hold"])
    await relaunched.appModel.load()
    let browser = await relaunched.browser.restoredBrowser(for: id)
    #expect(browser.tabs.map(\.url.absoluteString) == ["http://localhost:9/a"])
    #expect(browser.isVisible)
    await scenario.tearDown()
  }
}
