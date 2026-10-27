import Foundation
import Testing
import VibeDomain

@Suite("Worktree location (#432)")
struct WorktreeLocationTests {
  @Test("The template is read back as it was written, unknown braces kept as text")
  func template() {
    let location = WorktreeLocation(template: "~/Worktrees/{project}/{branch}-{nope}")
    #expect(
      location.parts == [
        .text("~/Worktrees/"), .variable(.project), .text("/"), .variable(.branch),
        .text("-{nope}"),
      ])
    #expect(location.template == "~/Worktrees/{project}/{branch}-{nope}")
  }

  @Test("Adjacent text is merged and empty text dropped")
  func merged() {
    let location = WorktreeLocation(parts: [.text("a"), .text(""), .text("b"), .variable(.date)])
    #expect(location.parts == [.text("ab"), .variable(.date)])
  }

  @Test("Each preset is recognised, the default is inside the repository")
  func presets() {
    #expect(WorktreeLocation.default.template == "{repo}/.claude/worktrees/{branch}")
    #expect(WorktreeLocation.default.isInsideRepository)
    for preset in WorktreeLocation.Preset.allCases {
      #expect(preset.location.preset == preset)
      #expect(preset.location.warning == nil)
    }
    #expect(WorktreeLocation(template: "{repo}/x/{session}").preset == nil)
  }

  @Test("The guards: empty, nothing distinctive, not absolute")
  func warnings() {
    #expect(WorktreeLocation(template: "").warning == .empty)
    #expect(WorktreeLocation(template: "~/Worktrees/{project}").warning == .notDistinctive)
    #expect(WorktreeLocation(template: "worktrees/{branch}").warning == .notAbsolute)
    #expect(WorktreeLocation(template: "/tmp/{ticket}").warning == nil)
  }

  @Test("Resolving leaves the unknown variables in braces")
  func resolved() {
    let location = WorktreeLocation.default
    #expect(location.resolved([.repository: "/r"]) == "/r/.claude/worktrees/{branch}")
  }

  @Test("A session's name as a folder's")
  func sessionFolder() {
    #expect(WorktreeLocation.folderName(session: "Bandeau de mise à jour !") == "bandeau-de-mise-a-jour")
    #expect(WorktreeLocation.folderName(branch: "feat/432-x") == "feat-432-x")
  }

  @Test("An exception replaces the general path for its repository only")
  func exceptions() throws {
    let own = WorktreeLocation(template: "/w/{branch}")
    let settings = WorktreeLocationSettings(exceptions: ["/a/repo": own])
    #expect(settings.location(for: "/a/repo/") == own)
    #expect(settings.location(for: "/b") == .default)
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(WorktreeLocationSettings.self, from: data) == settings)
  }
}
