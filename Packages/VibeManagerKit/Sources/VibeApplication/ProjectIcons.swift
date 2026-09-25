import Foundation
import VibeDomain

/// Finds the icon of a project in its folder, and turns it into the PNG that would be kept (#27).
///
/// Bounded in depth, in the number of entries read and in time: it runs while the creation sheet
/// is open, and an answer that comes too late is no answer at all.
public protocol ProjectIconFinding: Sendable {
  /// `nil` when the folder holds nothing usable: no icon, or one that cannot be read. Never an
  /// error — the session then wears what its name gives, as it always has.
  func icon(inFolder path: String) async -> ProjectIcon?
}

/// Finds nothing: a workspace assembled without the disk.
public struct NoProjectIcons: ProjectIconFinding {
  public init() {}
  public func icon(inFolder path: String) async -> ProjectIcon? { nil }
}

/// Where the icons of the sessions are kept, by content.
public protocol SessionIconStore: Sendable {
  /// Writes the icon, or nothing when the same one is already there.
  func save(_ icon: ProjectIcon) async throws
  /// The PNG of an icon, `nil` when its file is missing or unreadable.
  func pngData(for id: SessionIconID) async -> Data?
}

/// Keeps the icons for the run.
public actor InMemorySessionIconStore: SessionIconStore {
  private var icons: [SessionIconID: Data] = [:]
  private let failure: (any Error)?

  public init(failure: (any Error)? = nil) {
    self.failure = failure
  }

  public func save(_ icon: ProjectIcon) throws {
    if let failure { throw failure }
    icons[icon.id] = icon.pngData
  }

  public func pngData(for id: SessionIconID) -> Data? {
    icons[id]
  }
}
