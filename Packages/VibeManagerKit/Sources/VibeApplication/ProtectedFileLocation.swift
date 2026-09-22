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
  public static func covering(
    path: String,
    homeDirectoryPath: String = NSHomeDirectory()
  ) -> ProtectedFileLocation? {
    let candidate = (path as NSString).standardizingPath
    return allCases.first { location in
      let root = location.rootPath(homeDirectoryPath: homeDirectoryPath)
      return candidate == root || candidate.hasPrefix(root + "/")
    }
  }
}
