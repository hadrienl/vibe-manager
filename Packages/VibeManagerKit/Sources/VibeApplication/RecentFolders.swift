import Foundation
import VibeDomain

/// A folder a session was created in, as the New Session sheet offers it again (#39).
public struct RecentFolder: Hashable, Codable, Sendable {
  /// The path as the session received it: what is shown, and what goes back into the field.
  public let path: String
  /// The folder's identity. Two spellings of one folder — `/var/x` and `/private/var/x`, a folder
  /// reached through a link — share it, so choosing the folder again never lists it twice.
  public let key: String

  public init(path: String, key: String) {
    self.path = path
    self.key = key
  }

  /// A folder known by its spelling alone, for when the disk may not be read.
  public init(lexicalPath path: String) {
    self.init(path: path, key: Self.lexicalKey(of: path))
  }

  /// A path compared without touching the disk: tilde expanded, `.` and `..` resolved, no trailing
  /// slash. Reading the disk to compare better would raise the consent alert of a protected
  /// folder in the middle of drawing a form.
  public static func lexicalKey(of path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
  }
}

/// The folders sessions were created in, the most recent first, each once.
///
/// It is an interface convenience, not a fact about the work: it lives beside the layout rather
/// than in `sessions.json`, and losing it costs one trip through the open panel.
public struct RecentFolders: Equatable, Sendable {
  public static let limit = 10

  public private(set) var entries: [RecentFolder]

  public init(_ entries: [RecentFolder] = []) {
    var kept: [RecentFolder] = []
    var keys = Set<String>()
    for entry in entries where keys.insert(entry.key).inserted {
      kept.append(entry)
    }
    self.entries = Array(kept.prefix(Self.limit))
  }

  /// The folder at the top. An entry for the same folder moves up and takes the new spelling;
  /// the oldest entry goes once there are more than `limit`.
  public func recording(_ folder: RecentFolder) -> RecentFolders {
    RecentFolders([folder] + entries.filter { $0.key != folder.key })
  }

  public func removing(key: String) -> RecentFolders {
    RecentFolders(entries.filter { $0.key != key })
  }

  /// The history an existing installation starts with: the folder of each session, the most
  /// recently created first. Compared by spelling only — this runs at launch, where nothing may
  /// read a folder the user has not just designated.
  public static func seeded(from sessions: [WorkSession]) -> RecentFolders {
    let folders =
      sessions
      .sorted { $0.createdAt > $1.createdAt }
      .compactMap(folder(of:))
      .map(RecentFolder.init(lexicalPath:))
    return RecentFolders(folders)
  }

  /// The folder a session gives the history (#529): one the user started a session in. A
  /// coordinator's child gives none: its agent chose the folder, often a worktree of its own. A
  /// worktree the user chose gives the repository it belongs to — a task's folder, gone with it,
  /// is no place to start the next one from — recorded with the session (#525), or read in the
  /// path of one created before. `nil` for none.
  public static func folder(of session: WorkSession) -> String? {
    guard session.coordination?.coordinatorID == nil,
      let path = SessionFolderKey.primaryPath(of: session), !path.isEmpty
    else { return nil }
    return WorktreeRepository.inPath(of: path) ?? path
  }

  /// The history with each worktree replaced by its repository, read in the path (#529): what
  /// coordinators' children wrote in it before. The repository is listed where it, or one of its
  /// worktrees, was used last, under the identity its own entry had.
  public func replacingWorktrees() -> RecentFolders {
    var known: [String: RecentFolder] = [:]
    for entry in entries {
      for name in [entry.key, RecentFolder.lexicalKey(of: entry.path)] where known[name] == nil {
        known[name] = entry
      }
    }
    return RecentFolders(
      entries.map { entry in
        // The key was read on disk: through a link, the spelling alone names another folder.
        let canonical = WorktreeRepository.inPath(of: entry.key)
        guard let repository = WorktreeRepository.inPath(of: entry.path) ?? canonical else {
          return entry
        }
        let spelling = RecentFolder.lexicalKey(of: repository)
        let identity = canonical ?? spelling
        return known[identity] ?? known[spelling]
          ?? RecentFolder(path: repository, key: identity)
      })
  }
}

extension RecentFolders: Codable {
  /// Entry by entry: one that cannot be read is dropped, never the whole history.
  public init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var entries: [RecentFolder] = []
    while !container.isAtEnd {
      if let entry = try? container.decode(RecentFolder.self) {
        entries.append(entry)
      } else {
        // Skips what could not be read, so the next entry is looked at rather than this one again.
        _ = try? container.decode(DiscardedEntry.self)
      }
    }
    self.init(entries)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(contentsOf: entries)
  }

  private struct DiscardedEntry: Decodable {}
}

/// Reading and writing the recent folders, without telling the interface where they are kept.
public protocol RecentFolderStore: Sendable {
  /// `nil` when nothing was ever written — which is what allows the first history to be seeded
  /// from the sessions — and an empty history when one was written empty.
  func load() async -> RecentFolders?
  func save(_ folders: RecentFolders) async
}

public actor InMemoryRecentFolderStore: RecentFolderStore {
  private var folders: RecentFolders?

  public init(_ folders: RecentFolders? = nil) {
    self.folders = folders
  }

  public func load() -> RecentFolders? { folders }

  public func save(_ folders: RecentFolders) {
    self.folders = folders
  }
}

/// The names the sheet gives recent folders: the folder's own name, and when two of them share
/// it, the nearest enclosing folder that tells them apart — `api — client-a`.
public enum RecentFolderNames {
  public static func displayNames(for paths: [String]) -> [String] {
    let components = paths.map { path in
      URL(fileURLWithPath: RecentFolder.lexicalKey(of: path)).pathComponents.filter { $0 != "/" }
    }
    let names = components.map { $0.last ?? "/" }
    return components.indices.map { index in
      let name = names[index]
      let namesakes = components.indices.filter { $0 != index && names[$0] == name }
      guard !namesakes.isEmpty else { return name }
      let own = components[index]
      // The first enclosing folder, going up, that none of the namesakes has at the same depth.
      for depth in stride(from: 2, through: own.count, by: 1) {
        let ancestor = own[own.count - depth]
        let shared = namesakes.contains { other in
          components[other].count >= depth
            && components[other][components[other].count - depth] == ancestor
        }
        if !shared {
          return "\(name) — \(ancestor)"
        }
      }
      return name
    }
  }
}
