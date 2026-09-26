import Foundation

public enum WorkingDirectoryStatus: Hashable, Sendable {
  case usable
  case missing
  case notADirectory
  case unreadable
}

/// The only disk the creation use case touches, isolated so a test can decide what a folder is
/// without creating one.
public protocol WorkingDirectoryProbe: Sendable {
  func inspect(path: String) async -> WorkingDirectoryStatus
}

public struct FileManagerWorkingDirectoryProbe: WorkingDirectoryProbe {
  public init() {}

  /// On a queue of its own: `stat` on a network volume that went away blocks its thread for as
  /// long as it takes, and a thread of the cooperative pool blocked that way starves every task
  /// and actor of the application — the budget meant to give up on the folder included.
  public func inspect(path: String) async -> WorkingDirectoryStatus {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: Self.inspectBlocking(path: path))
      }
    }
  }

  private static func inspectBlocking(path: String) -> WorkingDirectoryStatus {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
    guard isDirectory.boolValue else { return .notADirectory }
    // A directory also has to be enterable, not merely listable: the terminal is started inside
    // it, and `chdir` needs the execute bit.
    guard manager.isReadableFile(atPath: path), manager.isExecutableFile(atPath: path) else {
      return .unreadable
    }
    return .usable
  }
}
