import Darwin
import Foundation
import Testing

@testable import VibeTerminal

@Suite struct ApplicationInstanceLockTests {
  private func location() -> TerminalHostLocation {
    TerminalHostLocation(
      dataDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("lock-\(UUID().uuidString)", isDirectory: true))
  }

  @Test func aSecondApplicationOnTheSameDataIsRefusedAndToldWhoHoldsIt() throws {
    let location = location()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    guard case .acquired(let first) = ApplicationInstanceLock.acquire(at: location) else {
      Issue.record("The first application should take the lock.")
      return
    }
    guard case .held(let holder) = ApplicationInstanceLock.acquire(at: location) else {
      Issue.record("The second application should be refused.")
      return
    }
    #expect(holder == getpid())
    withExtendedLifetime(first) {}
  }

  @Test func theLockIsTakenAgainOnceItsHolderIsGone() throws {
    let location = location()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    var first = ApplicationInstanceLock.acquire(at: location)
    #expect({ if case .acquired = first { true } else { false } }())
    first = nil
    guard case .acquired = ApplicationInstanceLock.acquire(at: location) else {
      Issue.record("A released lock should be taken again.")
      return
    }
  }

  @Test func anotherDataDirectoryIsNotHeldBack() throws {
    let one = location()
    let other = location()
    defer {
      try? FileManager.default.removeItem(at: one.directory)
      try? FileManager.default.removeItem(at: other.directory)
    }
    let first = ApplicationInstanceLock.acquire(at: one)
    guard case .acquired = ApplicationInstanceLock.acquire(at: other) else {
      Issue.record("Another data directory should have its own lock.")
      return
    }
    withExtendedLifetime(first) {}
  }
}
