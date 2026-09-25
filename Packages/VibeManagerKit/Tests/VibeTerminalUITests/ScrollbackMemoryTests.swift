import Darwin
import Foundation
import SwiftTerm
import Testing

/// What a terminal's scrollback costs, measured rather than guessed (#19): the history keeps 5,000
/// lines, and SwiftTerm's default view kept 500, so a replayed history was cut on screen.
@Suite("Scrollback memory")
struct ScrollbackMemoryTests {
  private final class Delegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  private static func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return Int(info.phys_footprint)
  }

  @Test(
    "Three terminals of 5,000 lines of scrollback, full, stay within the memory budget",
    .enabled(if: ProcessInfo.processInfo.environment["VIBE_PERFORMANCE"] != nil))
  func fullScrollback() {
    let delegate = Delegate()
    let before = Self.footprint()
    var terminals: [Terminal] = []
    let line = Array(
      ("\u{1B}[32m" + String(repeating: "scrollback-", count: 10) + "\u{1B}[0m\r\n").utf8)
    for _ in 0..<3 {
      let terminal = Terminal(
        delegate: delegate,
        options: TerminalOptions(cols: 120, rows: 50, scrollback: 5_000))
      for _ in 0..<5_200 { terminal.feed(byteArray: line) }
      terminals.append(terminal)
    }
    let cost = Self.footprint() - before

    print("Scrollback of 3 × 5,000 lines × 120 columns: \(cost / 1_048_576) MiB")
    #expect(terminals.count == 3)
    // A quarter of the application's 400 MB budget, for three full terminals: measured at about
    // 50 MB when this was decided.
    #expect(cost < 100 * 1_048_576)
  }
}
