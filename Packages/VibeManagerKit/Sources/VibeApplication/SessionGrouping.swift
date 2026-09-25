import Foundation
import VibeDomain

/// How the sidebar lists the sessions: one list, or one section per working folder (#27).
///
/// An enumeration rather than a flag, because grouping by priority (#63) is the next way to list
/// them.
public enum SidebarMode: String, Codable, CaseIterable, Sendable {
  case flat
  case byFolder
}

/// A working folder, as the groups compare it: through its symbolic links.
///
/// Stored as its path alone, so that a set of them is a list of paths in the preferences.
public struct SessionFolderKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
  public let path: String

  public init(path: String) {
    self.path = path
  }

  public init(from decoder: any Decoder) throws {
    path = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(path)
  }

  public static func < (lhs: SessionFolderKey, rhs: SessionFolderKey) -> Bool {
    lhs.path < rhs.path
  }

  public var description: String { path }

  /// The folder as written, tidied without touching the disk: tilde expanded, `.` and `..`
  /// resolved, no trailing slash. Good enough for almost every folder, and what a group is filed
  /// under until the disk has been asked.
  public static func lexical(_ path: String) -> SessionFolderKey {
    let expanded = (path as NSString).expandingTildeInPath
    // `isDirectory` is given, so the URL does not ask the disk what the path is.
    return SessionFolderKey(
      path: URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path)
  }

  /// The folder as the file system sees it. `/var` and `/private/var`, or a folder opened through
  /// a link, land on the same key; a folder that has gone is resolved through its deepest ancestor
  /// that still exists, so it keeps its key. Touches the disk: never called while drawing.
  public static func canonical(_ path: String) -> SessionFolderKey {
    SessionFolderKey(path: CanonicalPath.of(lexical(path).path))
  }

  /// The folder a session is filed under: the one its agent starts in, never a worktree the agent
  /// made nor a second repository (#12). `nil` for a session written before folders were required.
  public static func primaryPath(of session: WorkSession) -> String? {
    guard let path = session.repositories.first?.path, !path.isEmpty else { return nil }
    return path
  }
}

/// One section of the grouped sidebar.
public struct SessionGroup: Identifiable, Equatable, Sendable {
  /// `nil` for the sessions that have no folder at all.
  public let id: SessionFolderKey?
  /// The last component of the folder, followed by the parent that tells it apart when another
  /// group on screen has the same one: "api — client-a".
  public let folderName: String
  /// What the user renamed the group to, if they did.
  public let customName: String?
  /// The whole path, `~` for the home folder, for the help tag.
  public let displayPath: String
  /// Whether the folder was missing the last time the disk was asked.
  public let isMissing: Bool
  /// In the order of the sort in use.
  public let sessions: [WorkSession]

  public init(
    id: SessionFolderKey?,
    folderName: String,
    customName: String? = nil,
    displayPath: String,
    isMissing: Bool = false,
    sessions: [WorkSession]
  ) {
    self.id = id
    self.folderName = folderName
    self.customName = customName
    self.displayPath = displayPath
    self.isMissing = isMissing
    self.sessions = sessions
  }

  /// The name shown. The folder's own name is still there, in the help tag and for VoiceOver.
  public var title: String { customName ?? folderName }

  public var isRenamed: Bool { customName != nil }
}

/// The sidebar, as a value: the list that is drawn and the rules it is drawn by.
public enum SidebarContent: Equatable, Sendable {
  case flat([WorkSession])
  /// The groups of the sessions that are not archived, then the archived ones on their own.
  case grouped([SessionGroup], archived: [WorkSession])
}

/// Cuts a list of sessions into one group per working folder. Pure: the disk has been asked
/// beforehand, and the answers are passed in.
public enum SessionGrouping {
  /// - Parameters:
  ///   - sessions: already filtered and sorted. Grouping neither adds nor removes a session, and
  ///     never sorts again: a group lists its sessions in the order of the sort, and the groups
  ///     come in the order of their first session.
  ///   - key: the folder a session is filed under, `nil` for none.
  ///   - customNames: what the user renamed groups to.
  ///   - missingFolders: the folders the disk said were gone.
  public static func content(
    of sessions: [WorkSession],
    key: (WorkSession) -> SessionFolderKey?,
    customNames: [SessionFolderKey: String] = [:],
    missingFolders: Set<SessionFolderKey> = []
  ) -> SidebarContent {
    let archived = sessions.filter { $0.status == .archived }
    let current = sessions.filter { $0.status != .archived }
    return .grouped(
      groups(
        of: current, key: key, customNames: customNames, missingFolders: missingFolders),
      archived: archived)
  }

  public static func groups(
    of sessions: [WorkSession],
    key: (WorkSession) -> SessionFolderKey?,
    customNames: [SessionFolderKey: String] = [:],
    missingFolders: Set<SessionFolderKey> = []
  ) -> [SessionGroup] {
    var order: [SessionFolderKey] = []
    var members: [SessionFolderKey: [WorkSession]] = [:]
    var unfiled: [WorkSession] = []
    for session in sessions {
      guard let folder = key(session) else {
        unfiled.append(session)
        continue
      }
      if members[folder] == nil { order.append(folder) }
      members[folder, default: []].append(session)
    }

    let names = folderNames(of: order)
    var groups = order.map { folder in
      SessionGroup(
        id: folder,
        folderName: names[folder] ?? folder.path,
        customName: customNames[folder].flatMap(FolderLabel.normalized),
        displayPath: (folder.path as NSString).abbreviatingWithTildeInPath,
        isMissing: missingFolders.contains(folder),
        sessions: members[folder] ?? []
      )
    }
    // Last, whatever the sort: a store written before a folder was required, which is nobody's
    // project.
    if !unfiled.isEmpty {
      groups.append(SessionGroup(id: nil, folderName: "", displayPath: "", sessions: unfiled))
    }
    return groups
  }

  /// The short name of each folder: its last component, with the nearest parent that tells two
  /// of them apart when they share it — the way Xcode and VS Code name two files called the same.
  static func folderNames(of folders: [SessionFolderKey]) -> [SessionFolderKey: String] {
    let components = Dictionary(
      uniqueKeysWithValues: folders.map { folder in
        (folder, folder.path.split(separator: "/").map(String.init))
      })
    let byLast = Dictionary(grouping: folders) { components[$0]?.last ?? "/" }
    var names: [SessionFolderKey: String] = [:]
    for (last, homonyms) in byLast {
      guard homonyms.count > 1 else {
        names[homonyms[0]] = last
        continue
      }
      let depth = components.values.map(\.count).max() ?? 0
      var distinguished = false
      for level in stride(from: 2, through: depth, by: 1) {
        let parents = homonyms.map { folder -> String in
          let parts = components[folder] ?? []
          return parts.count >= level ? parts[parts.count - level] : ""
        }
        guard Set(parents).count == homonyms.count else { continue }
        for (folder, parent) in zip(homonyms, parents) {
          names[folder] = parent.isEmpty ? last : "\(last) — \(parent)"
        }
        distinguished = true
        break
      }
      if !distinguished {
        for folder in homonyms {
          names[folder] = (folder.path as NSString).abbreviatingWithTildeInPath
        }
      }
    }
    return names
  }
}

/// The name a user gives a group.
public enum FolderLabel {
  /// A name made of spaces is no name: the group goes back to its folder's.
  public static func normalized(_ label: String) -> String? {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Where the names given to groups are kept.
///
/// Text the user wrote, so it is kept with the sessions rather than with the preferences of this
/// Mac: a layout can be lost without harm, a name cannot.
public protocol FolderLabelStore: Sendable {
  func labels() async throws -> [SessionFolderKey: String]
  /// Names a group, or gives it back its folder's name with `nil`. Returns every name.
  @discardableResult
  func setLabel(_ label: String?, for folder: SessionFolderKey) async throws
    -> [SessionFolderKey: String]
}

/// Keeps the names for the run: a workspace assembled without a data folder.
public actor InMemoryFolderLabelStore: FolderLabelStore {
  private var stored: [SessionFolderKey: String]

  public init(labels: [SessionFolderKey: String] = [:]) {
    stored = labels
  }

  public func labels() -> [SessionFolderKey: String] {
    stored
  }

  @discardableResult
  public func setLabel(_ label: String?, for folder: SessionFolderKey) -> [SessionFolderKey: String]
  {
    stored[folder] = label.flatMap(FolderLabel.normalized)
    return stored
  }
}

/// Asks the disk where each working folder really is, away from the main thread.
public struct SessionFolderResolution: Equatable, Sendable {
  /// The canonical key of each path as sessions spell it.
  public var keys: [String: SessionFolderKey]
  public var missing: Set<SessionFolderKey>

  public init(keys: [String: SessionFolderKey] = [:], missing: Set<SessionFolderKey> = []) {
    self.keys = keys
    self.missing = missing
  }

  public static func resolve(_ paths: Set<String>) async -> SessionFolderResolution {
    await Task.detached(priority: .utility) {
      var resolution = SessionFolderResolution()
      for path in paths {
        let key = SessionFolderKey.canonical(path)
        resolution.keys[path] = key
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: key.path, isDirectory: &isDirectory)
          || !isDirectory.boolValue
        {
          resolution.missing.insert(key)
        }
      }
      return resolution
    }.value
  }
}
