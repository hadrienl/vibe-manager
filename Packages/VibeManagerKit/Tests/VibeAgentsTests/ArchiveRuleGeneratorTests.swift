import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeAgents

/// Runs nothing: records the request, writes `answer.json` in the folder as Codex would, and
/// prints `standardOutput` as Claude Code would.
private final class RuleRunner: SummaryProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [BoundedProcessRequest] = []
  let standardOutput: Data
  let answerFile: Data?

  init(standardOutput: Data = Data(), answerFile: Data? = nil) {
    self.standardOutput = standardOutput
    self.answerFile = answerFile
  }

  var requests: [BoundedProcessRequest] { lock.withLock { recorded } }

  func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult {
    lock.withLock { recorded.append(request) }
    let folder = URL(fileURLWithPath: try #require(request.workingDirectoryPath))
    if let answerFile { try answerFile.write(to: folder.appendingPathComponent("answer.json")) }
    return BoundedProcessResult(
      termination: .exited(0), standardOutput: standardOutput, standardError: Data(),
      outputTruncated: false)
  }
}

private let sentence =
  "Archive les sessions terminées à icône rouge le 15 du mois, et celles à icône verte en fin de semaine."
private let request = ArchiveRuleGenerationRequest(sentence: sentence, context: .sample)

private func answerData(rules: String) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "rules": rules, "question": NSNull(), "assumptions": [] as [Any],
  ])
}

@Suite("Rules translated by Claude Code (#405)")
struct ClaudeCodeArchiveRuleCommandTests {
  @Test("Without tools, MCP, hooks, settings nor memory, held to the schema; the sentence on stdin")
  func arguments() async throws {
    let arguments = try ClaudeCodeArchiveRuleCommand().arguments(
      for: request, in: URL(fileURLWithPath: "/tmp"))
    #expect(arguments.starts(with: ["-p", "--model", "sonnet", "--tools", ""]))
    for flag in ["--strict-mcp-config", "--no-session-persistence"] {
      #expect(arguments.contains(flag))
    }
    let schema = try #require(arguments.firstIndex(of: "--json-schema")).advanced(by: 1)
    #expect(arguments[schema] == ArchiveRuleSchema.forAgent())
    #expect(!arguments.joined().contains("icône rouge"))

    let output = try JSONSerialization.data(withJSONObject: [
      "is_error": false,
      "structured_output": try JSONSerialization.jsonObject(with: answerData(rules: objectiveText)),
    ])
    let runner = RuleRunner(standardOutput: output)
    let generator = CommandLineArchiveRuleGenerator(
      provider: MockAgentProvider(environment: [:]), command: ClaudeCodeArchiveRuleCommand(),
      runner: runner)
    let data = try await generator.generate(request)
    guard case .rules(let document, _, _) = try ArchiveRuleAnswer.decode(data).get() else {
      Issue.record("Expected rules")
      return
    }
    #expect(document.rules.count == 2)
    let input = String(
      decoding: try #require(runner.requests.first?.standardInput?.data), as: UTF8.self)
    #expect(input.hasSuffix("<sentence>\n\(sentence)\n</sentence>"))
    #expect(input.contains("Rouge: #B42318"))
  }
}

@Suite("Rules translated by Codex (#405)")
struct CodexArchiveRuleCommandTests {
  @Test("Ephemeral, read only, without the user's configuration; the last message is the answer")
  func answer() async throws {
    let generator = CommandLineArchiveRuleGenerator(
      provider: MockAgentProvider(environment: [:]), command: CodexArchiveRuleCommand(),
      runner: RuleRunner(answerFile: try answerData(rules: objectiveText)))
    let data = try await generator.generate(request)
    #expect((try? ArchiveRuleAnswer.decode(data).get()) != nil)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexRules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let arguments = try CodexArchiveRuleCommand().arguments(for: request, in: folder)
    #expect(arguments.contains("--ignore-user-config"))
    #expect(arguments.contains("read-only"))
    let input = String(decoding: CodexArchiveRuleCommand().input(for: request), as: UTF8.self)
    #expect(input.hasPrefix(ArchiveRuleInstructions.systemPrompt(context: .sample)))
  }
}

private let objectiveText = """
  rule "Rouges, le 15"
    archive done sessions where badge.color = #B42318
    on monthly 15 at 18:00

  rule "Vertes, en fin de semaine"
    archive done sessions where badge.color = #1E7F4D
    on weekly friday at 18:00
  """

/// The reference sentences of the ticket, with the real agents, on demand:
/// `VIBE_ARCHIVE_RULES_INTEGRATION=1 swift test --filter ArchiveRuleIntegrationTests`.
@Suite(
  "Reference sentences with the real agents (#405)",
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_ARCHIVE_RULES_INTEGRATION"] == "1"))
struct ArchiveRuleIntegrationTests {
  static let cases: [(String, @Sendable (ArchiveRuleAnswer) -> Bool)] = [
    (
      "Archive les sessions rouges le 15 du mois, les vertes en fin de semaine",
      { answer in
        guard case .rules(let document, _, _) = answer else { return false }
        return document.rules.map(\.schedule) == [
          .monthly([.number(15)], ArchiveTime(hour: 18, minute: 0)),
          .weekly([.friday], ArchiveTime(hour: 18, minute: 0)),
        ]
          && document.rules.map(\.condition) == [
            .test(ArchiveTest(.badgeColor, .equal, .color("#B42318"))),
            .test(ArchiveTest(.badgeColor, .equal, .color("#1E7F4D"))),
          ]
      }
    ),
    (
      "Chaque soir, archive ce qui est terminé depuis plus de 3 jours, sauf le projet client-x",
      { answer in
        guard case .rules(let document, _, _) = answer else { return false }
        return document.rules.first?.schedule == .daily(ArchiveTime(hour: 18, minute: 0))
          && document.protections.first?.condition
            == .test(ArchiveTest(.project, .equal, .text("client-x")))
      }
    ),
    (
      "Nettoie toutes les sessions terminées chaque soir à 19 h",
      { answer in
        guard case .rules(let document, _, _) = answer else { return false }
        return document.rules.first?.schedule == .daily(ArchiveTime(hour: 19, minute: 0))
          && document.rules.first?.condition == nil
      }
    ),
    (
      "Archive les sessions",
      { answer in
        if case .question = answer { return true }
        return false
      }
    ),
  ]

  @Test("Claude Code and Codex translate the reference sentences", arguments: [true, false])
  func references(claude: Bool) async throws {
    let generator =
      claude
      ? ClaudeCodeAgentProvider.make().archiveRuleGenerator()
      : CodexAgentProvider.make().archiveRuleGenerator()
    for (sentence, expectation) in Self.cases {
      let answer = try await GenerateArchiveRules(generator: generator)(
        ArchiveRuleGenerationRequest(sentence: sentence, context: .sample))
      #expect(expectation(answer), "\(sentence) → \(answer)")
    }
  }
}
