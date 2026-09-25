import Darwin
import Foundation

/// Brings the application's own folders back to owner only.
///
/// Every file the stores write is `0600` and every folder they create `0700`, but a folder that
/// already exists keeps its mode: one made by an early build, restored from a Time Machine backup
/// or copied by hand may be readable by the other accounts of the Mac — sessions, prompts and notes
/// included. At launch, the folders the application owns are tightened, and so are the files
/// directly in them.
///
/// Only folders the composition names are touched, never a parent: a store URL can point inside a
/// folder the application does not own, which is why the stores themselves leave existing folders
/// alone.
public enum DataDirectoryPermissions {
  /// Tightens `directories` and the regular files directly inside them. A missing folder is
  /// skipped, and so is a symbolic link, which is never followed. Returns what was changed.
  @discardableResult
  public static func repair(_ directories: [URL]) -> [URL] {
    var repaired: [URL] = []
    let folders = directories.filter { isOfType($0.path, S_IFDIR) }
    for directory in folders where tighten(directory.path, expecting: S_IFDIR) {
      repaired.append(directory)
    }
    for directory in folders {
      let entries =
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in entries {
        let path = (directory.path as NSString).appendingPathComponent(name)
        if tighten(path, expecting: S_IFREG) {
          repaired.append(URL(fileURLWithPath: path))
        }
      }
    }
    return repaired
  }

  /// Whether `path` was of `type` and open to the group or the others, now removed. The owner's
  /// own bits are left as they are.
  private static func isOfType(_ path: String, _ type: mode_t) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0 && status.st_mode & S_IFMT == type
  }

  private static func tighten(_ path: String, expecting type: mode_t) -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0, status.st_mode & S_IFMT == type else { return false }
    guard status.st_mode & 0o077 != 0 else { return false }
    return chmod(path, status.st_mode & 0o700) == 0
  }
}
