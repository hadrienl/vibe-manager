import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Sharing ticket resolvers in a file (#89)")
struct TicketResolverExchangeTests {
  private let redmine = TicketResolver(
    name: "Redmine", pattern: #"https://redmine\.acme\.fr/issues/(?<number>[0-9]+)"#,
    shortID: "#{number}", titleCleanup: [" - Redmine$"])

  @Test("What is exported is imported back, without where a preset came from")
  func roundTrip() throws {
    let data = try TicketResolverExchange.encode(
      [redmine, TicketResolverPresets.github], exportedAt: Date(timeIntervalSince1970: 0))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(#""format" : "vibe-manager.ticket-resolvers""#))
    #expect(!text.contains("preset"))
    let decoded = try TicketResolverExchange.decode(data)
    #expect(decoded.skipped == 0)
    #expect(decoded.resolvers.map(\.name) == ["Redmine", "GitHub"])
    #expect(decoded.resolvers[0].pattern == redmine.pattern)
    #expect(decoded.resolvers.allSatisfy { $0.preset == nil })
  }

  @Test("An invalid resolver is left out, the others are imported")
  func invalidLeftOut() throws {
    let json = """
      {"format": "vibe-manager.ticket-resolvers", "version": 1, "resolvers": [
        {"id": "\(UUID())", "name": "Broken", "pattern": "(", "shortID": "x"},
        {"name": "No identifier"},
        {"id": "\(redmine.id)", "name": "Redmine", "pattern": "\(redmine.pattern.replacingOccurrences(of: "\\", with: "\\\\"))",
         "shortID": "#{number}"}
      ]}
      """
    let decoded = try TicketResolverExchange.decode(Data(json.utf8))
    #expect(decoded.resolvers.map(\.name) == ["Redmine"])
    #expect(decoded.skipped == 2)
  }

  @Test("A file that is not one, or from a later version, is refused whole")
  func refused() {
    #expect(throws: TicketResolverExchange.DecodingError.notAResolverFile) {
      try TicketResolverExchange.decode(
        Data(#"{"format": "other", "version": 1, "resolvers": []}"#.utf8))
    }
    #expect(throws: TicketResolverExchange.DecodingError.unsupportedVersion(9)) {
      try TicketResolverExchange.decode(
        Data(#"{"format": "vibe-manager.ticket-resolvers", "version": 9, "resolvers": []}"#.utf8))
    }
  }

  @Test("A known identifier replaces its resolver; a name taken is suffixed")
  func merge() {
    var renamed = redmine
    renamed.shortID = "R{number}"
    var other = redmine
    other.id = UUID()
    let merged = TicketResolverExchange.merge([renamed, other], into: [redmine])
    #expect(merged.count == 2)
    #expect(merged[0].shortID == "R{number}")
    #expect(merged[1].name == "Redmine 2")
  }
}
