import Foundation
import VibeApplication

/// Asks the file system what no API will answer: does this process have Full Disk Access?
///
/// The witness is the user's own TCC database. It exists on every Mac, and only Full Disk Access
/// opens it — which is exactly why the terminals do the same thing. Just as importantly, a process
/// without the access is refused *silently*: the path is hidden rather than denied (observed
/// `errno = 2`), with no alert. A probe that raised the alert it exists to prevent would be absurd.
///
/// Nothing is read from the file. Being allowed to open it is the whole answer.
public struct TCCFullDiskAccessProbe: FullDiskAccessProbe {
  public static var defaultWitnessPath: String {
    NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
  }

  private let witnessPath: String

  /// The witness is a parameter so the probe can be tested against a file that is merely
  /// readable, instead of against the real permission state of whoever runs the tests.
  public init(witnessPath: String? = nil) {
    self.witnessPath = witnessPath ?? Self.defaultWitnessPath
  }

  public func status() async -> FullDiskAccessStatus {
    guard let handle = FileHandle(forReadingAtPath: witnessPath) else { return .notGranted }
    try? handle.close()
    return .granted
  }
}
