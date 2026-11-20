import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeProcess

@testable import VibeAgents

private actor AntigravityRepository: SessionRepository {
  var stored: [SessionID: WorkSession] = [:]
  func sessions() -> [WorkSession] { Array(stored.values) }
  func session(id: SessionID) -> WorkSession? { stored[id] }
  func save(_ session: WorkSession) { stored[session.id] = session }
}

@Suite("Antigravity integration contracts")
struct AntigravityTests {
  private let identifier = "8a33e630-aece-4796-b0c7-eb5ef638cf2f"

  private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func base(
    location: ExecutableLocation = .found(path: "/bin/agy", source: .candidateDirectory),
    probe: StubProcessProbe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "1.5.5")))
  ) -> CommandLineAgentProvider {
    CommandLineAgentProvider(
      descriptor: AntigravityAgentProvider.descriptor,
      specification: AntigravityAgentProvider.specification,
      argumentBuilder: AntigravityArgumentBuilder(),
      availabilityProbe: AgentAvailabilityProbe(
        descriptor: AntigravityAgentProvider.descriptor,
        specification: AntigravityAgentProvider.specification,
        locator: StubLocator(location: location), probe: probe, environment: [:]),
      environment: ["HOME": "/Users/test", "GEMINI_API_KEY": "do-not-forward"])
  }

  @Test("Detection has no speculative authentication probe and filters secrets")
  func detection() async throws {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "1.5.5")))
    let provider = base(probe: probe)
    #expect(await provider.availability(forceRefresh: false).state == .available)
    let prompt = "-é\n\"quoted\" $(touch /tmp/never) | cat"
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/tmp/project", initialPrompt: prompt))
    #expect(plan.arguments.suffix(2) == ["--prompt-interactive", prompt])
    #expect(plan.environment["GEMINI_API_KEY"] == nil)
    #expect(probe.invocations.allSatisfy { $0.arguments == ["--version"] })
  }

  @Test("Resume names exactly one conversation and leaves the initial prompt absent")
  func resume() throws {
    let request = AgentLaunchRequest(
      workingDirectoryPath: "/tmp/project", modelID: "new-model",
      resume: .identifier(identifier.uppercased()))
    let args = try AntigravityArgumentBuilder().arguments(
      for: request, promptDelivery: .none, descriptor: AntigravityAgentProvider.descriptor)
    #expect(args.suffix(4) == ["--conversation", identifier, "--model", "new-model"])
    #expect(!args.contains("--continue"))
  }

  @Test("Invalid options, NUL and oversized TUI prompts fail before launching")
  func validation() async throws {
    for request in [
      AgentLaunchRequest(workingDirectoryPath: "/tmp", resume: .identifier("--continue")),
      AgentLaunchRequest(workingDirectoryPath: "/tmp", modelID: "--print"),
      AgentLaunchRequest(workingDirectoryPath: "/tmp", initialPrompt: "a\u{0}b"),
      AgentLaunchRequest(
        workingDirectoryPath: "/tmp", initialPrompt: String(repeating: "é", count: 9000)),
    ] {
      await #expect(throws: AgentLaunchError.self) { try await base().launchPlan(for: request) }
    }
    await #expect(throws: AgentLaunchError.self) {
      try await base(location: .notFound).launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: "/tmp"))
    }
  }

  private func settings(in arguments: [String]) throws -> [String: Any] {
    let index = try #require(arguments.firstIndex(of: "--settings"))
    return try #require(
      JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any])
  }

  @Test("Manual overrides a global automatic policy; auto selects native review and the sandbox")
  func approvalArguments() throws {
    for resume in [AgentResumeRequest.none, .identifier(identifier)] {
      for mode in AgentApprovalMode.allCases {
        let request = AgentLaunchRequest(
          workingDirectoryPath: "/tmp", resume: resume, approvalMode: mode)
        let args = try AntigravityArgumentBuilder().arguments(
          for: request, promptDelivery: .none, descriptor: AntigravityAgentProvider.descriptor)
        let overrides = try settings(in: args)
        #expect(overrides["agentMode"] as? String == (mode == .manual ? "" : "auto"))
        #expect(
          overrides["toolPermission"] as? String
            == (mode == .manual ? "request-review" : "proceed-in-sandbox"))
        #expect(args.contains("--sandbox") == (mode == .autoReview))
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--prompt-interactive"))
        if mode == .autoReview {
          #expect(args.prefix(3) == ["--sandbox", "--mode", "auto"])
        }
      }
    }
    let defaultArgs = try AntigravityArgumentBuilder().arguments(
      for: AgentLaunchRequest(workingDirectoryPath: "/tmp"), promptDelivery: .none,
      descriptor: AntigravityAgentProvider.descriptor)
    // No mode chosen: the user's own `/config` is left as it is.
    #expect(!defaultArgs.contains("--settings"))
    #expect(!defaultArgs.contains("--sandbox"))
  }

  @MainActor
  @Test("The provider reads its current preference at each launch and native resume")
  func approvalPreference() async throws {
    let preferences = InMemoryAgentApprovalPreferences()
    let availability = AgentAvailabilityProbe(
      descriptor: AntigravityAgentProvider.descriptor,
      specification: AntigravityAgentProvider.specification,
      locator: StubLocator(location: .found(path: "/bin/agy", source: .candidateDirectory)),
      probe: StubProcessProbe(), environment: [:])
    let provider = AntigravityAgentProvider(
      base: base(),
      catalog: AntigravityModelCatalog(
        availability: availability, probe: StubProcessProbe(), environment: [:]),
      approvalPreferences: preferences)
    let request = AgentLaunchRequest(workingDirectoryPath: "/tmp", resume: .identifier(identifier))
    let unset = try await provider.launchPlan(for: request)
    #expect(!unset.arguments.contains("--settings"))
    preferences.setMode(.manual, for: AntigravityAgentProvider.id)
    let manual = try await provider.launchPlan(for: request)
    #expect(try settings(in: manual.arguments)["agentMode"] as? String == "")
    preferences.setMode(.autoReview, for: AntigravityAgentProvider.id)
    let automatic = try await provider.launchPlan(for: request)
    #expect(automatic.arguments.contains("--sandbox"))
    preferences.setMode(.manual, for: AntigravityAgentProvider.id)
    let backToManual = try await provider.launchPlan(for: request)
    #expect(!backToManual.arguments.contains("--sandbox"))
    #expect(
      try settings(in: backToManual.arguments)["toolPermission"] as? String == "request-review")
  }

  @Test("Activity shares one settings object with policy, including a prompt named --settings")
  func activityKeepsApprovalMode() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    for mode in AgentApprovalMode.allCases {
      let original = try await base().launchPlan(
        for: AgentLaunchRequest(
          workingDirectoryPath: "/tmp", initialPrompt: "--settings", approvalMode: mode))
      // No user settings file is touched: compose the same generated status JSON as the provider.
      let reporting = AntigravitySettings.merging(
        AntigravityStatusCommand.settings(home: folder), into: original)
      // One option, one literal prompt.
      #expect(reporting.arguments.filter { $0 == "--settings" }.count == 2)
      #expect(reporting.arguments.suffix(2) == ["--prompt-interactive", "--settings"])
      let merged = try settings(in: reporting.arguments)
      #expect(merged["statusLine"] is [String: Any])
      #expect(
        merged["toolPermission"] as? String
          == (mode == .manual ? "request-review" : "proceed-in-sandbox"))
      #expect(merged["agentMode"] as? String == (mode == .manual ? "" : "auto"))
    }
    let withoutOverrides = AgentLaunchPlan(
      providerID: AntigravityAgentProvider.id, executablePath: "/bin/agy",
      arguments: ["--prompt-interactive", "--settings"], environment: [:],
      workingDirectoryPath: "/tmp", promptDelivery: .argument)
    let added = AntigravitySettings.merging(#"{"agentMode":"auto"}"#, into: withoutOverrides)
    #expect(added.arguments.prefix(2) == ["--prompt-interactive", "--settings"])
    #expect(added.arguments[2] == "--settings")
    #expect(added.arguments[3] == #"{"agentMode":"auto"}"#)
  }

  @Test("The account catalog ignores noise, duplicates and malformed rows")
  func catalog() {
    let models = AntigravityModelCatalog.decode(
      "Fetching models...\nmodel-a\tModel A\nmodel-a\tDuplicate\n--flag\tBad\nbad/path\tBad\nmodel-b\tModel B\n"
    )
    #expect(models.map(\.id) == ["model-a", "model-b"])
    #expect(models.map(\.displayName) == ["Model A", "Model B"])
    #expect(models.allSatisfy { !$0.isDefault })
  }

  private func event(_ state: String, pending: Bool = false, background: Bool = false)
    -> AgentActivityEvent
  {
    AgentActivityEvent(
      name: AntigravityStatusCommand.event, date: Date(),
      payload: Data(
        "{\"conversation_id\":\"\(identifier)\",\"agent_state\":\"\(state)\",\"pending\":\(pending),\"background\":\(background)}"
          .utf8))
  }

  @Test("Concurrent model pickers share one request and a failing catalog is cached too")
  func sharedCatalog() async {
    let probe = ScriptedProcessProbe(responses: [
      .success(ProbeResult(exitCode: 0, standardOutput: "1.5.5")),
      .success(ProbeResult(exitCode: 1, standardError: "unavailable")),
    ])
    let availability = AgentAvailabilityProbe(
      descriptor: AntigravityAgentProvider.descriptor,
      specification: AntigravityAgentProvider.specification,
      locator: StubLocator(location: .found(path: "/bin/agy", source: .candidateDirectory)),
      probe: probe, environment: [:])
    let catalog = AntigravityModelCatalog(
      availability: availability, probe: probe, environment: [:])
    async let first = catalog.models()
    async let second = catalog.models()
    let both = await [first, second]
    #expect(both == [[], []])
    #expect(await catalog.models().isEmpty)
    #expect(probe.invocations.filter { $0.arguments == ["models"] }.count == 1)
    #expect(probe.invocations.last?.timeout == .seconds(15))
  }

  @Test("Snapshots do not manufacture unread answers and background work keeps working")
  func activity() {
    let decoder = AntigravitySignalDecoder()
    #expect(decoder.signal(for: event("idle")) == .interrupted)
    #expect(decoder.signal(for: event("idle")) == nil)
    #expect(decoder.signal(for: event("working")) == .promptSubmitted(byUser: true))
    #expect(decoder.signal(for: event("tool_use")) == nil)
    #expect(decoder.signal(for: event("working")) == nil)
    #expect(decoder.signal(for: event("idle", background: true)) == nil)
    #expect(decoder.signal(for: event("idle")) == .turnEnded)
    #expect(decoder.signal(for: event("idle")) == nil)
    #expect(decoder.conversationIdentifier(in: event("idle")) == identifier)
    #expect(decoder.answerKeymap == nil)
    #expect(decoder.approvalAnswerKeys.isEmpty)
  }

  @Test("An approval followed by the end of the turn between two snapshots ends the turn")
  func approvalThenIdle() {
    let decoder = AntigravitySignalDecoder()
    _ = decoder.signal(for: event("working"))
    #expect(decoder.signal(for: event("working", pending: true)) != nil)
    #expect(decoder.signal(for: event("idle")) == .turnEnded)
  }

  @Test("A prompt after a failed turn is the user's: what the failure asked is behind")
  func promptAfterFailure() {
    let decoder = AntigravitySignalDecoder()
    _ = decoder.signal(for: event("working"))
    #expect(decoder.signal(for: event("error")) != nil)
    #expect(decoder.signal(for: event("working")) == .promptSubmitted(byUser: true))
    // A session first seen mid-turn: nobody just typed.
    let adopted = AntigravitySignalDecoder()
    #expect(adopted.signal(for: event("tool_use")) == .promptSubmitted(byUser: false))
  }

  @Test("A dialog is announced without fabricated choices and resolves when work resumes")
  func permissions() {
    let decoder = AntigravitySignalDecoder()
    #expect(decoder.signal(for: event("working", pending: true)) != nil)
    #expect(decoder.signal(for: event("working", pending: true)) == nil)
    #expect(decoder.signal(for: event("working")) == .questionResolved)
    #expect(decoder.signal(for: event("idle")) == .turnEnded)
  }

  @Test("The actual status command retains only allowed fields and preserves user output")
  func statusCommand() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("activity.log")
    let data = try JSONSerialization.data(withJSONObject: [
      "conversation_id": identifier, "agent_state": "idle", "task_count": 1,
      "tool_confirmation_pending": true,
      "subagents": [["name": "private-name", "status": "running"]],
      "email": "private-email", "lastUserInput": "private-prompt",
    ])
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/bin/sh",
        arguments: ["-c", AntigravityStatusCommand.script, "test", "printf own-status"],
        environment: ["PATH": "/usr/bin:/bin", "VIBE_AGENT_ACTIVITY_LOG": log.path],
        timeout: .seconds(5), standardInput: BoundedProcessInput(data: data)))
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "own-status")
    let written = try String(contentsOf: log, encoding: .utf8)
    #expect(!written.contains("private"))
    let payload = try #require(written.split(separator: "\t").last)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(object["conversation_id"] as? String == identifier)
    #expect(object["pending"] as? Bool == true)
    #expect(object["background"] as? Bool == true)
    #expect(object.count == 4)
  }

  @Test("The user's own command gets a payload over 64 KiB whole; the time is the log's")
  func statusCommandLargePayload() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("activity.log")
    let data = try JSONSerialization.data(withJSONObject: [
      "conversation_id": identifier, "agent_state": "working", "task_count": 0,
      "subagents": [["status": "done"], ["status": "idle"]],
      "large": String(repeating: "x", count: 200_000),
    ])
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/bin/sh",
        arguments: ["-c", AntigravityStatusCommand.script, "test", "/usr/bin/wc -c"],
        environment: ["PATH": "/usr/bin:/bin", "VIBE_AGENT_ACTIVITY_LOG": log.path],
        timeout: .seconds(5), standardInput: BoundedProcessInput(data: data)))
    #expect(result.exitCode == 0)
    let counted = String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(Int(counted) == data.count)
    let fields = try String(contentsOf: log, encoding: .utf8).split(separator: "\t")
    let time = try #require(Double(fields[1]))
    #expect(abs(time - Date().timeIntervalSince1970) < 60)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(fields[2].utf8)) as? [String: Any])
    #expect(object["agent_state"] as? String == "working")
    #expect(object["background"] as? Bool == false)
    #expect(object["pending"] as? Bool == false)
  }

  @Test("A status line the user turned off stays invisible while the reporter runs")
  func disabledStatusLine() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(".gemini/antigravity-cli/settings.json")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"statusLine":{"enabled":false,"command":"printf hidden"}}"#.utf8).write(to: file)
    let object = try #require(
      JSONSerialization.jsonObject(
        with: Data(AntigravityStatusCommand.settings(home: folder).utf8)) as? [String: Any])
    let status = try #require(object["statusLine"] as? [String: Any])
    #expect(status["enabled"] as? Bool == true)
    #expect(status["stack_with_default"] as? Bool == false)
    #expect((status["command"] as? String)?.contains("printf hidden") == false)
  }

  @Test("Status injection preserves padding, stack preference and the enabled user command")
  func settings() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(".gemini/antigravity-cli/settings.json")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"statusLine":{"command":"printf user-status","padding":2,"stack_with_default":false},"agentMode":"plan"}"#
        .utf8
    ).write(to: file)
    let generated = AntigravityStatusCommand.settings(home: folder)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(generated.utf8)) as? [String: Any])
    let status = try #require(object["statusLine"] as? [String: Any])
    #expect(status["padding"] as? Int == 2)
    #expect(status["stack_with_default"] as? Bool == false)
    #expect((status["command"] as? String)?.contains("printf user-status") == true)
    #expect(object["agentMode"] == nil)
  }

  @Test("Only this process's named, written conversation becomes resumable, including adoption")
  func capture() async throws {
    let home = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    var session = WorkSession(name: "Test")
    session.agent = SessionAgentConfiguration(providerID: "antigravity")
    let repository = AntigravityRepository()
    await repository.save(session)
    let observer = AntigravityLaunchObserver(
      sessionID: session.id, repository: repository, home: home)
    await observer.conversationNamed(identifier)
    #expect(await observer.awaitedResumeIdentifier() == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == nil)
    let file = try #require(AntigravityAgentProvider.transcript(identifier: identifier, home: home))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: file)
    await observer.finished()  // includes the final look, even before the watch wakes
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    #expect(await observer.awaitedResumeIdentifier() == nil)
    let adopted = AntigravityLaunchObserver(
      sessionID: session.id, repository: repository, home: home)
    await adopted.adopted(awaitedResumeIdentifier: identifier)
    await adopted.finished()
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("Two launches in the same folder never adopt each other's transcript")
  func separateConversations() async throws {
    let home = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    let repository = AntigravityRepository()
    let first = WorkSession(
      name: "First", agent: SessionAgentConfiguration(providerID: "antigravity"))
    let second = WorkSession(
      name: "Second", agent: SessionAgentConfiguration(providerID: "antigravity"))
    await repository.save(first)
    await repository.save(second)
    let one = AntigravityLaunchObserver(sessionID: first.id, repository: repository, home: home)
    let two = AntigravityLaunchObserver(sessionID: second.id, repository: repository, home: home)
    let secondID = UUID().uuidString.lowercased()
    let file = try #require(AntigravityAgentProvider.transcript(identifier: identifier, home: home))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: file)
    await one.conversationNamed(identifier)
    await two.conversationNamed(secondID)
    await one.finished()
    await two.finished()
    #expect(await repository.session(id: first.id)?.agent?.resumeIdentifier == identifier)
    #expect(await repository.session(id: second.id)?.agent?.resumeIdentifier == nil)
    #expect(AntigravityAgentProvider.transcript(identifier: "../../escape", home: home) == nil)
  }

  @Test(
    "The numbered transcript preserves prompt literals, replaces snapshots and skips unknown shapes"
  )
  func conversation() {
    let decoder = AntigravityConversationDecoder()
    func line(_ object: [String: Any]) {
      decoder.consume(try! JSONSerialization.data(withJSONObject: object))
    }
    line([
      "step_index": 0, "type": "USER_INPUT", "source": "USER_EXPLICIT",
      "content":
        "<USER_REQUEST>\n-é\n</USER_REQUEST> literal\n</USER_REQUEST>\n<ADDITIONAL_METADATA>private</ADDITIONAL_METADATA>",
    ])
    line(["step_index": 1, "type": "PLANNER_RESPONSE", "content": "first"])
    line(["step_index": 1, "type": "PLANNER_RESPONSE", "content": "final"])
    line(["step_index": 2, "type": "UNKNOWN", "content": "not a message"])
    #expect(decoder.entries.count == 2)
    #expect(
      decoder.entries[0].content == .userPrompt("-é\n</USER_REQUEST> literal", attachments: []))
    #expect(decoder.entries[1].content == .agentText("final"))
  }

  @Test("An empty request is no prompt, and does not crash the reading")
  func emptyRequest() {
    #expect(AntigravityConversationDecoder.request(in: "<USER_REQUEST>\n</USER_REQUEST>") == "")
    #expect(
      AntigravityConversationDecoder.request(
        in: "<USER_REQUEST>\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>") == "")
    #expect(
      AntigravityConversationDecoder.request(in: "<USER_REQUEST>\nHi\n</USER_REQUEST>") == "Hi")
    #expect(AntigravityConversationDecoder.request(in: "plain") == nil)
    let decoder = AntigravityConversationDecoder()
    decoder.consume(
      try! JSONSerialization.data(withJSONObject: [
        "step_index": 0, "type": "USER_INPUT", "source": "USER_EXPLICIT",
        "content": "<USER_REQUEST>\n</USER_REQUEST>",
      ]))
    #expect(decoder.entries.isEmpty)
  }

  @Test("A step published again after others is replaced where it was, the latest one at the end")
  func stepsOutOfOrder() {
    let decoder = AntigravityConversationDecoder()
    func line(_ step: Int, _ text: String) {
      decoder.consume(
        try! JSONSerialization.data(withJSONObject: [
          "step_index": step, "type": "PLANNER_RESPONSE", "content": text,
        ]))
    }
    line(0, "a")
    line(1, "b")
    line(0, "a2")
    line(2, "c")
    line(2, "c2")
    #expect(
      decoder.entries.map(\.content) == [.agentText("a2"), .agentText("b"), .agentText("c2")])
    let long = AntigravityConversationDecoder()
    for step in 0..<2_000 {
      for snapshot in 0..<3 {
        long.consume(
          try! JSONSerialization.data(withJSONObject: [
            "step_index": step, "type": "PLANNER_RESPONSE", "content": "s\(snapshot)",
          ]))
      }
    }
    #expect(long.entries.count == 2_000)
    #expect(long.entries.last?.content == .agentText("s2"))
  }
}
