import Testing
import VibeApplication

@Suite("Agent version parsing")
struct AgentVersionTests {
  @Test(
    "Versions are extracted from the noise CLIs print around them",
    arguments: [
      ("1.2.3", AgentVersion(major: 1, minor: 2, patch: 3)),
      ("claude 2.4.1 (Claude Code)", AgentVersion(major: 2, minor: 4, patch: 1)),
      ("v0.45.0", AgentVersion(major: 0, minor: 45, patch: 0)),
      ("codex-cli 1.0.0-beta.2", AgentVersion(major: 1, minor: 0, patch: 0)),
      ("3.9", AgentVersion(major: 3, minor: 9, patch: 0)),
      ("stub-agent 2.4.1+build.7", AgentVersion(major: 2, minor: 4, patch: 1)),
    ]
  )
  func parsesVersions(output: String, expected: AgentVersion) {
    #expect(AgentVersion(parsing: output) == expected)
  }

  @Test(
    "Output without a version is rejected rather than guessed",
    arguments: ["", "nightly", "build 7", "unknown version"]
  )
  func rejectsUnparsableOutput(output: String) {
    #expect(AgentVersion(parsing: output) == nil)
  }

  @Test("The anchored line wins over an unrelated number printed first")
  func prefersAnchoredLine() {
    let output = "warning: requires Node 18.0.0\nstub-agent 2.4.1"

    #expect(
      AgentVersion(parsing: output, anchor: "stub-agent")
        == AgentVersion(major: 2, minor: 4, patch: 1)
    )
    // Without an anchor the first line still wins, which is why providers pass one.
    #expect(AgentVersion(parsing: output) == AgentVersion(major: 18, minor: 0, patch: 0))
  }

  @Test("An anchor that matches nothing falls back to the first parsable line")
  func fallsBackWhenAnchorIsAbsent() {
    #expect(
      AgentVersion(parsing: "codex 1.2.3", anchor: "claude")
        == AgentVersion(major: 1, minor: 2, patch: 3)
    )
  }

  @Test("Versions compare component by component")
  func comparesVersions() {
    #expect(AgentVersion(major: 1, minor: 9, patch: 9) < AgentVersion(major: 2))
    #expect(AgentVersion(major: 2, minor: 0, patch: 1) > AgentVersion(major: 2))
    #expect(AgentVersion(major: 2, minor: 10) > AgentVersion(major: 2, minor: 9))
    #expect(
      AgentVersion(major: 1, minor: 2, patch: 3) == AgentVersion(major: 1, minor: 2, patch: 3))
  }
}
