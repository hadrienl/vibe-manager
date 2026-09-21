import Foundation

public struct GitRepositoryDescriptor: Hashable, Sendable {
  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }
}

public protocol GitWorkspaceService: Sendable {
  func repositories() async throws -> [GitRepositoryDescriptor]
}
