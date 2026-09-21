import Foundation
import Testing

@testable import VibeDomain

@Test("A work session can round-trip through Codable")
func workSessionCodableRoundTrip() throws {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let identifier = try #require(UUID(uuidString: "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD"))
  let session = WorkSession(
    id: SessionID(rawValue: identifier),
    name: "Bootstrap the app",
    status: .active,
    createdAt: date,
    updatedAt: date
  )

  let data = try JSONEncoder().encode(session)
  let decoded = try JSONDecoder().decode(WorkSession.self, from: data)

  #expect(decoded == session)
}
