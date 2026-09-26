import Foundation
import VibeDomain

/// A repository, as the journal needs to name its branches: the clone it belongs to — the same
/// for all its worktrees — and the forge it is pushed to.
public struct RepositoryIdentity: Hashable, Sendable {
  /// The main worktree: where a branch is revealed.
  public let rootPath: String
  /// The Git directory the clone and all its worktrees share, canonical.
  public let commonDirectory: String
  public let remote: RemoteRepository?

  public init(rootPath: String, commonDirectory: String, remote: RemoteRepository?) {
    self.rootPath = rootPath
    self.commonDirectory = commonDirectory
    self.remote = remote
  }

  public var name: String { (rootPath as NSString).lastPathComponent }
}

/// Where a repository is pushed: `github.com` and `hadrienl/vibe-manager`.
public struct RemoteRepository: Hashable, Sendable {
  public let host: String
  public let path: String

  public init(host: String, path: String) {
    self.host = host
    self.path = path
  }

  /// `git@host:path.git`, `ssh://git@host:22/path.git`, `https://user@host/path.git`.
  public init?(remoteURL: String) {
    var text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    var host: String
    var path: String
    if let schemeRange = text.range(of: "://") {
      text = String(text[schemeRange.upperBound...])
      guard let slash = text.firstIndex(of: "/") else { return nil }
      host = String(text[..<slash])
      path = String(text[text.index(after: slash)...])
      if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
      if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
    } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {
      host = String(text[..<colon])
      path = String(text[text.index(after: colon)...])
      if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    } else {
      return nil
    }
    if path.hasSuffix(".git") { path.removeLast(4) }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    host = host.lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    guard !host.isEmpty, path.contains("/") else { return nil }
    self.host = host
    self.path = path
  }

  /// Which forge it looks like, from its host alone: `nil` for one that says neither.
  public var forge: Forge? {
    if host.contains("gitlab") { return .gitlab }
    if host.contains("github") { return .github }
    return nil
  }

  /// The page of a branch on the forge, when the forge is known.
  public func branchURL(_ branch: String) -> URL? {
    let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
    switch forge {
    case .github: return URL(string: "https://\(host)/\(path)/tree/\(encoded)")
    case .gitlab: return URL(string: "https://\(host)/\(path)/-/tree/\(encoded)")
    case nil: return nil
    }
  }
}

/// Asks Git which repository a folder is in. Read only, like everything the application asks Git.
public protocol RepositoryIdentityResolving: Sendable {
  func identity(ofDirectory path: String) async -> RepositoryIdentity?
}

/// `git rev-parse` and `git remote get-url`, once per folder for the length of the run: a remote
/// that changes while an agent works is rare, and every command of a transcript would otherwise
/// cost two processes.
public actor GitRepositoryIdentityResolver: RepositoryIdentityResolving {
  private let git: any GitCommandRunner
  private var cache: [String: RepositoryIdentity?] = [:]

  public init(git: any GitCommandRunner) {
    self.git = git
  }

  public func identity(ofDirectory path: String) async -> RepositoryIdentity? {
    if let known = cache[path] { return known }
    let identity = await read(path)
    cache[path] = identity
    return identity
  }

  private func read(_ path: String) async -> RepositoryIdentity? {
    guard FileManager.default.fileExists(atPath: path),
      let result = try? await git.run(
        ["rev-parse", "--show-toplevel", "--git-common-dir"], in: path),
      result.succeeded
    else { return nil }
    let lines = result.text.split(separator: "\n").map(String.init)
    guard lines.count == 2 else { return nil }
    let top = lines[0]
    let common = CanonicalPath.of(
      lines[1].hasPrefix("/") ? lines[1] : (path as NSString).appendingPathComponent(lines[1]))
    // The clone the worktrees hang from: the folder of its `.git`.
    let root =
      (common as NSString).lastPathComponent == ".git"
      ? (common as NSString).deletingLastPathComponent : CanonicalPath.of(top)
    // The remote `gh` would choose: `upstream` when there is one.
    var remote: RemoteRepository?
    for name in ["upstream", "origin"] {
      if let answer = try? await git.run(["remote", "get-url", name], in: path),
        answer.succeeded, let parsed = RemoteRepository(remoteURL: answer.text)
      {
        remote = parsed
        break
      }
    }
    return RepositoryIdentity(rootPath: root, commonDirectory: common, remote: remote)
  }
}

/// Turns what the transcript named into resources, asking Git for what it alone knows: the
/// repository of a folder, its remote. A sighting nothing can complete is dropped: a number whose
/// repository is unknown is not a ticket anyone can open.
public struct ResourceResolution: Sendable {
  private let repositories: any RepositoryIdentityResolving

  public init(repositories: any RepositoryIdentityResolving) {
    self.repositories = repositories
  }

  public func resources(for sightings: [ResourceSighting]) async -> [SessionResource] {
    var resources: [SessionResource] = []
    for sighting in sightings {
      if let resource = await resource(for: sighting) { resources.append(resource) }
    }
    return resources
  }

  func resource(for sighting: ResourceSighting) async -> SessionResource? {
    switch sighting {
    case .resource(let resource):
      return resource
    case .reference(let forge, let kind, let number, let repository, let directory, let inv, let at):
      let remote = await remote(forge: forge, repository: repository, directory: directory)
      guard let remote else { return nil }
      let page: String
      switch (forge, kind) {
      case (.github, .pullRequest): page = "pull/\(number)"
      case (.github, _): page = "issues/\(number)"
      case (.gitlab, .pullRequest): page = "-/merge_requests/\(number)"
      case (.gitlab, _): page = "-/issues/\(number)"
      }
      guard let url = URL(string: "https://\(remote.host)/\(remote.path)/\(page)") else {
        return nil
      }
      // Through the URL recognizer, so that a number and the URL of the same ticket share a key.
      return ResourceRecognizer.resource(for: url, involvement: inv, at: at)
    case .branch(let name, let directory, let involvement, let at):
      guard let identity = await repositories.identity(ofDirectory: directory) else { return nil }
      return SessionResource(
        key: "branch:\(identity.commonDirectory)/\(name)",
        kind: .branch,
        label: name,
        context: identity.name,
        target: .branch(
          repositoryPath: identity.rootPath, webURL: identity.remote?.branchURL(name)),
        involvement: involvement,
        firstSeenAt: at)
    case .worktree(let path, let involvement, let at):
      let canonical = CanonicalPath.of(path)
      let identity = await repositories.identity(ofDirectory: canonical)
      return SessionResource(
        key: "worktree:\(canonical)",
        kind: .worktree,
        label: (canonical as NSString).lastPathComponent,
        context: identity?.name,
        target: .folder(canonical),
        involvement: involvement,
        firstSeenAt: at)
    }
  }

  private func remote(
    forge: Forge, repository: String?, directory: String?
  ) async -> RemoteRepository? {
    let local: RemoteRepository?
    if let directory {
      local = await repositories.identity(ofDirectory: directory)?.remote
    } else {
      local = nil
    }
    guard let repository else { return local }
    let parts = repository.split(separator: "/").map(String.init)
    switch forge {
    case .github:
      // `OWNER/REPO` or `HOST/OWNER/REPO`.
      if parts.count == 3 {
        return RemoteRepository(
          host: parts[0].lowercased(), path: parts[1...].joined(separator: "/"))
      }
      guard parts.count == 2 else { return nil }
      let host = local?.forge == .github ? local?.host ?? "github.com" : "github.com"
      return RemoteRepository(host: host, path: repository)
    case .gitlab:
      if repository.hasPrefix("http"), let parsed = RemoteRepository(remoteURL: repository) {
        return parsed
      }
      guard parts.count >= 2 else { return nil }
      let host = local?.forge == .gitlab ? local?.host ?? "gitlab.com" : "gitlab.com"
      return RemoteRepository(host: host, path: repository)
    }
  }
}
