import Darwin
import Foundation
import VibeApplication

/// Asks the file system what no API will answer: does this process have Full Disk Access?
///
/// The witnesses are TCC's own databases: only Full Disk Access opens them — which is exactly why
/// the terminals do the same thing. Just as importantly, a process without the access is refused
/// *silently*, with no alert. A probe that raised the alert it exists to prevent would be absurd.
///
/// A witness answers only when it is there. Allowed to open it: granted. Refused (`EPERM`): not
/// granted. Missing (`ENOENT`): this system keeps nothing there, and the next witness is asked.
/// macOS 27 no longer shows the user's database at its old path, with or without the access
/// (#225): read as a refusal, as it once was, that silence said "not granted" to everyone.
///
/// Nothing is read from the file. Being allowed to open it is the whole answer.
public struct TCCFullDiskAccessProbe: FullDiskAccessProbe {
  /// In order: the system's database, on every Mac and still guarded by the access in macOS 27,
  /// then the user's, for the systems that keep it.
  public static var defaultWitnessPaths: [String] {
    [
      "/Library/Application Support/com.apple.TCC/TCC.db",
      NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
    ]
  }

  private let witnessPaths: [String]

  /// The witnesses are a parameter so the probe can be tested against files that are merely
  /// readable, instead of against the real permission state of whoever runs the tests.
  public init(witnessPaths: [String]? = nil) {
    self.witnessPaths = witnessPaths ?? Self.defaultWitnessPaths
  }

  public init(witnessPath: String) {
    self.init(witnessPaths: [witnessPath])
  }

  public func status() async -> FullDiskAccessStatus {
    for path in witnessPaths {
      if let answer = Self.answer(of: path) { return answer }
    }
    // No witness answered: "granted" is never said without proof.
    return .notGranted
  }

  /// `nil` when the witness is not there to answer.
  private static func answer(of path: String) -> FullDiskAccessStatus? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor < 0 else {
      close(descriptor)
      return .granted
    }
    return errno == ENOENT || errno == ENOTDIR ? nil : .notGranted
  }
}
