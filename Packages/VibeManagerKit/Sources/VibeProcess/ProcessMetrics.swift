import Darwin
import Foundation

/// What the kernel says a process costs, read the way Activity Monitor and `footprint` read it.
public enum ProcessMetrics {
  /// The physical footprint of this process, in bytes: `TASK_VM_INFO.phys_footprint`, the figure
  /// Activity Monitor calls Memory and the one the system's memory pressure acts on.
  public static func physicalFootprint() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int(info.phys_footprint)
  }

  /// CPU time this process has used, user and system together.
  public static func cpuTime() -> Duration {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let microseconds =
      Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
      + Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
    return .microseconds(microseconds)
  }

  /// CPU time another process of the same user has used, `nil` when it cannot be read.
  public static func cpuTime(of processIdentifier: pid_t) -> Duration? {
    var info = proc_taskinfo()
    let size = proc_pidinfo(
      processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
    guard size == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = info.pti_total_user + info.pti_total_system
    let nanoseconds = ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    return .nanoseconds(Int64(nanoseconds))
  }
}
