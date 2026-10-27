import Testing

@testable import VibeUI

@Suite("Reasoning effort: what is kept on the session (#411)")
struct EffortKeepingTests {
  @Test("The agent's default is never kept, whether its settings name a level or not")
  func defaultNotKept() {
    // A first turn of Codex, config.toml naming no level: the model's own default.
    #expect(!AppModel.keepsSaidEffort("medium", kept: nil))
    #expect(!AppModel.keepsSaidEffort(nil, kept: nil))
  }

  @Test("Once a level is chosen, one set by hand in the terminal replaces it")
  func handSetKept() {
    #expect(AppModel.keepsSaidEffort("xhigh", kept: "low"))
    #expect(!AppModel.keepsSaidEffort("low", kept: "low"))
    #expect(!AppModel.keepsSaidEffort(nil, kept: "low"))
  }
}
