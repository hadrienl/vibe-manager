import VibeDomain

public protocol SessionRepository: Sendable {
  func sessions() async throws -> [WorkSession]
  func save(_ session: WorkSession) async throws
}
