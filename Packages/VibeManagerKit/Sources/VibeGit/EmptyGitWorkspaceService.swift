import VibeApplication

public struct EmptyGitWorkspaceService: GitWorkspaceService {
  public init() {}

  public func repositories() async throws -> [GitRepositoryDescriptor] {
    []
  }
}
