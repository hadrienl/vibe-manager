import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The extra accounts of Claude Code and Codex (#478), as the settings show them.
@MainActor
@Observable
public final class AgentAccountsSettingsModel {
  public private(set) var accounts: [AgentAccount] = []
  /// Why the file could not be read or written, kept until a save succeeds.
  public private(set) var storeError: String?

  /// A save waits for the agents to be detected again: a second click must not add twice.
  @ObservationIgnored private var isSaving = false
  @ObservationIgnored private let repository: any AgentAccountRepository
  @ObservationIgnored private let home: String
  @ObservationIgnored private let defaultDirectories: [EndpointHarness: String]
  @ObservationIgnored private let didSave: @MainActor () async -> Void

  public init(
    repository: any AgentAccountRepository, home: String,
    defaultDirectories: [EndpointHarness: String],
    didSave: @escaping @MainActor () async -> Void = {}
  ) {
    self.repository = repository
    self.home = home
    self.defaultDirectories = defaultDirectories
    self.didSave = didSave
  }

  public func load() async {
    do {
      accounts = try await repository.accounts()
      storeError = nil
    } catch {
      storeError = error.localizedDescription
    }
  }

  public func issues(of account: AgentAccount) -> [AgentAccount.ValidationIssue] {
    account.validationIssues(
      among: accounts, home: home, defaultDirectory: defaultDirectories[account.harness],
      canonical: Self.canonicalPath)
  }

  /// The folder a path names on the disk, from the deepest folder of it that exists: links
  /// followed, in the case the file system keeps — `~/.Claude`, or a link to `~/.claude`, is
  /// `~/.claude` on a disk that ignores case.
  nonisolated static func canonicalPath(_ path: String) -> String {
    var existing = URL(fileURLWithPath: path)
    var missing: [String] = []
    while existing.path != "/" {
      if let resolved = realpath(existing.path, nil) {
        defer { free(resolved) }
        let found = String(cString: resolved)
        return missing.reversed().reduce(found) { ($0 as NSString).appendingPathComponent($1) }
      }
      missing.append(existing.lastPathComponent)
      existing.deleteLastPathComponent()
    }
    return path
  }

  /// Creates the folder if need be, and registers the account. `false`, with `storeError` said,
  /// when it could not be.
  @discardableResult
  public func add(_ account: AgentAccount) async -> Bool {
    guard !isSaving, issues(of: account).isEmpty,
      let directory = AgentAccount.resolvedDirectory(account.configurationDirectory, home: home)
    else { return false }
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    } catch {
      storeError = error.localizedDescription
      return false
    }
    return await save(accounts + [account])
  }

  @discardableResult
  public func rename(_ id: UUID, to name: String) async -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else {
      return false
    }
    var list = accounts
    list[index].name = trimmed
    return await save(list)
  }

  /// Removes the agent, never its folder: its sign-in and conversations stay on the disk.
  @discardableResult
  public func delete(_ id: UUID) async -> Bool {
    await save(accounts.filter { $0.id != id })
  }

  private func save(_ list: [AgentAccount]) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    do {
      try await repository.save(list)
      storeError = nil
    } catch {
      storeError = error.localizedDescription
      return false
    }
    await didSave()
    // Only now: the form still shows what was just added, which would read as a folder taken.
    accounts = list
    return true
  }
}
