import Foundation
import Testing

@testable import VibeApplication

@Suite("The skills and commands listed under / in the composer (#219)")
struct AgentCommandsTests {
  private static func skill(
    _ name: String, _ description: String = "", origin: AgentCommand.Origin? = .user,
    trigger: String = "/", aliases: [String] = []
  ) -> AgentCommand {
    AgentCommand(
      name: name, invocation: trigger + name, description: description, kind: .skill,
      origin: origin, aliases: aliases)
  }

  private static func command(
    _ name: String, _ description: String = "", origin: AgentCommand.Origin? = .builtin,
    aliases: [String] = []
  ) -> AgentCommand {
    AgentCommand(
      name: name, invocation: "/" + name, description: description, kind: .command,
      origin: origin, aliases: aliases)
  }

  private static func query(_ draft: String, _ triggers: Set<Character> = ["/"])
    -> AgentCommandQuery?
  {
    AgentCommandQuery(draft: draft, triggers: triggers)
  }

  @Test("The list opens on a trigger typed first, blanks aside, and closes at a blank after it")
  func opening() {
    #expect(Self.query("/")?.text == "")
    #expect(Self.query("/deb")?.text == "deb")
    #expect(Self.query("  /deb")?.text == "deb")
    #expect(Self.query("/deb ") == nil)
    #expect(Self.query("/deb\n") == nil)
    #expect(Self.query("/a b") == nil)
    #expect(Self.query("see /deb") == nil)
    #expect(Self.query("") == nil)
    #expect(Self.query("$img") == nil)
    #expect(Self.query("$img", ["/", "$"])?.trigger == "$")
    #expect(Self.query("!ls", ["/", "$"]) == nil)
  }

  @Test("Inserting replaces what was typed with the invocation and a space")
  func inserting() {
    let debug = Self.skill("prisme-ai:debug-events")
    #expect(AgentCommandQuery.draft(inserting: debug, into: "/deb") == "/prisme-ai:debug-events ")
    #expect(
      AgentCommandQuery.draft(inserting: debug, into: "  /deb") == "  /prisme-ai:debug-events ")
  }

  @Test("Unfiltered: skills of the project, the user, the plugins, then commands, by name")
  func order() {
    let index = AgentCommandIndex([
      Self.command("model"),
      Self.command("export", origin: .user),
      Self.skill("zeta", origin: .plugin("p")),
      Self.skill("beta", origin: .user),
      Self.skill("alpha", origin: .project),
      Self.skill("gamma", origin: nil),
      Self.skill("Alpha2", origin: .user),
      Self.command("clear"),
    ])
    let names = index.matches(for: Self.query("/")!).map(\.command.name)
    #expect(names == ["alpha", "Alpha2", "beta", "zeta", "gamma", "export", "clear", "model"])
  }

  @Test("Filtered: name first, then a part of a namespaced name, an alias, inside, description")
  func ranks() {
    let index = AgentCommandIndex([
      Self.skill("xdebug", "Nothing."),
      Self.skill("notes", "Takes notes to debug later."),
      Self.skill("prisme-ai:debug-events", "Traces."),
      Self.skill("debugger", "Runs."),
      Self.command("code-review", aliases: ["debug-review"]),
      Self.skill("other", "Unrelated."),
    ])
    let matches = index.matches(for: Self.query("/debug")!)
    #expect(
      matches.map(\.command.name) == [
        "debugger", "prisme-ai:debug-events", "xdebug", "notes", "code-review",
      ])
    #expect(matches[0].nameRanges == [0..<5])
    #expect(matches[1].nameRanges == [10..<15])
    #expect(matches[2].nameRanges == [1..<6])
    #expect(matches[3].descriptionRanges == [15..<20])
    #expect(matches[4].nameRanges.isEmpty)
    #expect(index.matches(for: Self.query("/zzz")!).isEmpty)
  }

  @Test("Case and accents do not count")
  func folding() {
    let index = AgentCommandIndex([Self.skill("Résumé", "Écrit un résumé.")])
    #expect(index.matches(for: Self.query("/resu")!).map(\.command.name) == ["Résumé"])
    #expect(index.matches(for: Self.query("/RÉS")!).first?.nameRanges == [0..<3])
    #expect(index.matches(for: Self.query("/ecrit")!).first?.descriptionRanges == [0..<5])
  }

  @Test("`$` lists only what goes by it; `/` lists everything")
  func triggers() {
    let index = AgentCommandIndex([
      Self.skill("imagegen", trigger: "$"), Self.command("compact"),
    ])
    #expect(index.triggers == ["/", "$"])
    #expect(index.matches(for: Self.query("$", ["/", "$"])!).map(\.command.name) == ["imagegen"])
    #expect(
      index.matches(for: Self.query("/", ["/", "$"])!).map(\.command.name)
        == ["imagegen", "compact"])
    #expect(AgentCommandIndex([Self.command("compact")]).triggers == ["/"])
  }

  @Test("An empty argument hint is none")
  func hint() {
    let blank = AgentCommand(
      name: "a", invocation: "/a", description: "", argumentHint: "  ", kind: .skill, origin: nil)
    #expect(blank.argumentHint == nil)
  }

  @Test("Typing stays quick with hundreds of entries")
  func speed() {
    let commands = (0..<600).map {
      Self.skill("plugin-\($0 % 7):skill-number-\($0)", "Does thing \($0) for the user, well.")
    }
    let index = AgentCommandIndex(commands)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for text in ["/", "/s", "/sk", "/ski", "/skil", "/skill-number-4", "/well", "/zzz"] {
        _ = index.matches(for: Self.query(text)!)
      }
    }
    // Eight keys: well under a frame each, even on a slow runner.
    #expect(elapsed < .milliseconds(200))
  }

  // MARK: - Catalog

  private final class Listing: AgentCommandListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads: [Bool] = []
    var reads: [Bool] { lock.withLock { _reads } }
    var failing = false
    var commands: [AgentCommand] = [AgentCommandsTests.skill("one")]

    func commands(inWorkingDirectory workingDirectoryPath: String, refresh: Bool) async throws
      -> AgentCommandList
    {
      lock.withLock { _reads.append(refresh) }
      if lock.withLock({ failing }) { throw CancellationError() }
      return AgentCommandList(
        commands: lock.withLock { commands },
        problems: [AgentCommandProblem(path: "/tmp/broken/SKILL.md", message: "bad")])
    }
  }

  private static let key = AgentCommandCatalog.Key(
    providerID: AgentProviderID("claude-code"), workingDirectoryPath: "/tmp/project")

  @Test("A list is read once while fresh, again from disk once stale, and kept when a read fails")
  func catalog() async {
    let log = RecordingDiagnosticLog()
    let listing = Listing()
    let fresh = AgentCommandCatalog(freshness: .seconds(60), diagnostics: log)
    #expect(await fresh.cached(Self.key) == nil)
    #expect(await fresh.refreshed(Self.key, from: listing)?.commands.map(\.name) == ["one"])
    #expect(await fresh.refreshed(Self.key, from: listing)?.commands.map(\.name) == ["one"])
    #expect(listing.reads == [false])
    #expect(log.names == ["agent.commands.unreadable"])

    let stale = AgentCommandCatalog(freshness: .zero, diagnostics: log)
    _ = await stale.refreshed(Self.key, from: listing)
    listing.commands = [Self.skill("two")]
    #expect(await stale.refreshed(Self.key, from: listing)?.commands.map(\.name) == ["two"])
    listing.failing = true
    #expect(await stale.refreshed(Self.key, from: listing)?.commands.map(\.name) == ["two"])
    #expect(listing.reads == [false, false, true, true])
    #expect(await stale.cached(Self.key)?.commands.map(\.name) == ["two"])
  }

  @Test("Folders and agents each have their list")
  func keys() async {
    let catalog = AgentCommandCatalog()
    let listing = Listing()
    _ = await catalog.refreshed(Self.key, from: listing)
    let other = AgentCommandCatalog.Key(
      providerID: AgentProviderID("codex"), workingDirectoryPath: "/tmp/project")
    #expect(await catalog.cached(other) == nil)
  }
}
