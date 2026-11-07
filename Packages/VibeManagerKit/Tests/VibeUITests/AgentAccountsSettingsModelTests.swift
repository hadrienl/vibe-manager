import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// #478: an extra account in a folder that is the agent's own would be the same account.
@MainActor
@Suite("The extra accounts of the settings")
struct AgentAccountsSettingsModelTests {
  @Test("A link to the agent's folder, or its name in another case, is the agent's folder")
  func sameFolderOtherwiseWritten() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vibe-accounts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let own = root.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: own)
    let model = AgentAccountsSettingsModel(
      repository: InMemoryAgentAccountRepository(), home: root.path,
      defaultDirectories: [.claudeCode: own.path])
    func issues(_ directory: String) -> [AgentAccount.ValidationIssue] {
      model.issues(
        of: AgentAccount(name: "Two", harness: .claudeCode, configurationDirectory: directory))
    }

    #expect(issues("~/link") == [.directoryIsDefault])
    #expect(issues("~/link/") == [.directoryIsDefault])
    #expect(issues("~/.claude-2").isEmpty)
    let values = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    if values.volumeSupportsCaseSensitiveNames == false {
      #expect(issues("~/.Claude") == [.directoryIsDefault])
    }
  }
}
