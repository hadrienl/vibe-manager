import Darwin

/// Who started a process, and when it started, read from the kernel (#69).
///
/// The start time is what tells a process apart from a later one given the same number: a check
/// that walks up from a process compares it at each step.
public enum ProcessAncestry {
  public struct Entry: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let parentProcessIdentifier: pid_t
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
  }

  /// One process, or `nil` when it is gone or belongs to someone else.
  public static func entry(of processIdentifier: pid_t) -> Entry? {
    guard processIdentifier > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return nil
    }
    return Entry(
      processIdentifier: processIdentifier,
      parentProcessIdentifier: pid_t(info.pbi_ppid),
      startSeconds: info.pbi_start_tvsec,
      startMicroseconds: info.pbi_start_tvusec)
  }

  /// The process and its ancestors, nearest first, up to `launchd` or the first that cannot be
  /// read. Bounded: a chain longer than this is not one a terminal makes.
  public static func lineage(of processIdentifier: pid_t, limit: Int = 64) -> [Entry] {
    var result: [Entry] = []
    var next = processIdentifier
    while result.count < limit, let entry = entry(of: next) {
      result.append(entry)
      guard entry.parentProcessIdentifier > 1, entry.parentProcessIdentifier != next else { break }
      next = entry.parentProcessIdentifier
    }
    return result
  }
}
