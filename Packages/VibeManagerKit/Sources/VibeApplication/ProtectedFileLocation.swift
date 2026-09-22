import Foundation

/// A folder macOS guards behind a consent alert.
///
/// Recognised from the path alone, deliberately: the point is to warn *before* anything reads the
/// disk, and a check that touched the folder to find out would raise the very alert it is meant to
/// announce.
public enum ProtectedFileLocation: Hashable, Sendable, CaseIterable {
  case desktop
  case documents
  case downloads
  case iCloudDrive
  case externalVolume

  public var label: String {
    switch self {
    case .desktop: return "your Desktop"
    case .documents: return "your Documents folder"
    case .downloads: return "your Downloads folder"
    case .iCloudDrive: return "iCloud Drive"
    case .externalVolume: return "external volumes"
    }
  }

  fileprivate func rootPath(homeDirectoryPath: String) -> String {
    let home = (homeDirectoryPath as NSString).standardizingPath
    switch self {
    case .desktop: return home + "/Desktop"
    case .documents: return home + "/Documents"
    case .downloads: return home + "/Downloads"
    case .iCloudDrive: return home + "/Library/Mobile Documents"
    case .externalVolume: return "/Volumes"
    }
  }
}

extension ProtectedFileLocation {
  /// The protected location this path sits in, or `nil` when nothing guards it.
  ///
  /// A user's own repositories are almost never in one of these, which is why refusing Full Disk
  /// Access is a workable answer rather than a broken application.
  /// - Parameter isBootVolumeMount: whether a `/Volumes/<name>` mount point is the startup disk.
  ///   macOS firmlinks the startup volume into `/Volumes` under its own name, so a repository
  ///   perfectly at home in `/Users` can also be reached as `/Volumes/Macintosh HD/Users/…` —
  ///   the same folder, announced as "external volumes" unless someone asks which volume it is.
  ///   Asking reads the mount point's own metadata, never anything inside it, so the rule above
  ///   still holds: nothing here opens a guarded folder.
  public static func covering(
    path: String,
    homeDirectoryPath: String = NSHomeDirectory(),
    isBootVolumeMount: (String) -> Bool = ProtectedFileLocation.mountIsBootVolume
  ) -> ProtectedFileLocation? {
    let candidate = (path as NSString).standardizingPath
    return allCases.first { location in
      let root = location.rootPath(homeDirectoryPath: homeDirectoryPath)
      guard isWithin(candidate, root: root) else { return false }
      guard location == .externalVolume, let mount = mountPoint(of: candidate) else { return true }
      return !isBootVolumeMount(mount)
    }
  }

  /// Compared without regard to case, because the volumes these folders live on almost never keep
  /// any. `~/documents/notes` is the Documents folder — typed that way it is just as guarded, and
  /// a warning that goes missing because of a lowercase "d" is a warning that failed.
  private static func isWithin(_ candidate: String, root: String) -> Bool {
    let candidate = candidate.lowercased()
    let root = root.lowercased()
    return candidate == root || candidate.hasPrefix(root + "/")
  }

  /// `/Volumes/Backup/repo` → `/Volumes/Backup`. Nil when the path names no volume at all.
  private static func mountPoint(of path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2 else { return nil }
    return "/" + components[0] + "/" + components[1]
  }

  /// Whether a mount point is the startup volume, asked of the filesystem because no path can
  /// answer it: a firmlink leaves no trace in the name.
  public static func mountIsBootVolume(_ mountPath: String) -> Bool {
    let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
    guard
      let mounted = try? URL(fileURLWithPath: mountPath).resourceValues(forKeys: keys)
        .volumeIdentifier,
      let boot = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys).volumeIdentifier
    else { return false }
    return mounted.isEqual(boot)
  }
}
