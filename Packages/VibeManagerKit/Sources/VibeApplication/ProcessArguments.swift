import Darwin
import Foundation

/// A process's arguments, as the kernel keeps them: what a terminal's command or an agent was
/// started with (#43, #352).
public enum ProcessArguments {
  /// `KERN_PROCARGS2`: the argument count, the executable's path, padding, then the arguments.
  public static func of(_ processIdentifier: pid_t) -> [String]? {
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
    var size = 0
    guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard count > 0 else { return nil }
    var index = MemoryLayout<Int32>.size
    // The executable's path, then the NULs that pad it.
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while index < size, arguments.count < Int(count) {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return arguments
  }
}
