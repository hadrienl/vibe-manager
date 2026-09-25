import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("The digest a summary is written from")
struct TurnDigestTests {
  @Test("Prompts, actions, the agent's last words, resources and latest entries, numbered turns")
  func content() throws {
    let url = try #require(URL(string: "https://gitlab.com/g/p/-/merge_requests/3"))
    let digest = TurnDigest.make(
      turns: [
        DigestTurn(
          prompts: ["Review the MR"], actions: ["Bash: glab mr view 3"], agentText: "LGTM"),
        DigestTurn(prompts: ["Commit"], actions: ["Bash: git commit -m fix"]),
      ],
      resources: [
        SessionResource(
          key: "k", kind: .pullRequest, label: "!3", context: "g/p", target: .web(url),
          involvement: .viewed, firstSeenAt: Date())
      ],
      recentEntries: [JournalEntry(text: "Created the branch", at: Date(), providerID: nil)])
    #expect(digest.contains("## Turn 1"))
    #expect(digest.contains("## Turn 2"))
    #expect(digest.contains("- Bash: glab mr view 3"))
    #expect(digest.contains("Agent said last: LGTM"))
    #expect(digest.contains(url.absoluteString))
    #expect(digest.contains("- Created the branch"))
  }

  @Test("Bounded: the actions in the middle are replaced by their count, no turn is dropped")
  func bound() {
    let turns = (0..<5).map { index in
      DigestTurn(
        prompts: [String(repeating: "p", count: 5_000)],
        actions: (0..<400).map { "Bash: command number \($0) of turn \(index)" },
        agentText: String(repeating: "a", count: 5_000))
    }
    let digest = TurnDigest.make(turns: turns, resources: [], recentEntries: [])
    #expect(digest.utf8.count <= TurnDigest.byteLimit)
    #expect(digest.contains("## Turn 5"))
    #expect(digest.contains("more actions"))
  }
}
