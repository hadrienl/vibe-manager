import Foundation

/// An icon found in a project's folder, turned into the PNG the application keeps.
///
/// What is previewed in the creation sheet is exactly what is stored: the file found is converted
/// once, when it is found, and never read again.
public struct ProjectIcon: Hashable, Sendable {
  public let id: SessionIconID
  public let pngData: Data

  public init(id: SessionIconID, pngData: Data) {
    self.id = id
    self.pngData = pngData
  }
}
