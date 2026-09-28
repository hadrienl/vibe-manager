import Foundation
import Testing
import VibeLocalizationTesting

@testable import VibeApplication

@Suite("The library of avatars: its rules")
struct AvatarLibraryRulesTests {
  @Test("An identifier reads back as it was written: default, or a UUID")
  func identifiers() throws {
    let uuid = UUID()
    #expect(AvatarID("default") == .default)
    #expect(AvatarID(uuid.uuidString) == .stored(uuid))
    #expect(AvatarID("Avatar") == nil)
    let encoded = try JSONEncoder().encode([AvatarID.default, .stored(uuid)])
    #expect(String(decoding: encoded, as: UTF8.self) == "[\"default\",\"\(uuid.uuidString)\"]")
    #expect(try JSONDecoder().decode([AvatarID].self, from: encoded) == [.default, .stored(uuid)])
  }

  @Test("The default avatar first, then the others in the order they entered, whatever their names")
  func order() {
    let first = UUID()
    let second = UUID()
    let entries = [
      AvatarLibraryEntry(
        id: .stored(second), state: .draft(basedOn: nil), manifest: nil,
        addedAt: Date(timeIntervalSince1970: 20)),
      AvatarLibraryEntry(
        id: .stored(first), state: .kept, manifest: nil, addedAt: Date(timeIntervalSince1970: 10)),
      AvatarLibraryEntry(id: .default, state: .kept, manifest: nil, addedAt: .distantFuture),
    ]
    #expect(
      AvatarLibraryRules.ordered(entries).map(\.id) == [.default, .stored(first), .stored(second)])
  }

  @Test("A name keeps its first line, trimmed, and at most 60 characters; blank is no name")
  func names() {
    #expect(AvatarLibraryRules.name("  Renard roux  \nà écharpe") == "Renard roux")
    #expect(AvatarLibraryRules.name("\n\n  Robot") == "Robot")
    #expect(AvatarLibraryRules.name(String(repeating: "a", count: 80))?.count == 60)
    #expect(AvatarLibraryRules.name(" \n\t ") == nil)
  }

  @Test("A copy is named after its original, in the user's language, within 60 characters")
  func copyNames() {
    #expect(AvatarLibraryRules.copyName(of: "Renard") == "Renard (copy)")
    #expect(
      Localization.string("\("Renard") (copy)", module: "VibeApplication", in: "fr")
        == "Renard (copie)")
    #expect(
      Localization.string("Default Avatar", module: "VibeApplication", in: "fr")
        == "Avatar par défaut")
    let long = AvatarLibraryRules.copyName(of: String(repeating: "b", count: 60))
    #expect(long.count == AvatarManifest.maximumNameLength)
    #expect(long.hasSuffix("b (copy)"))
    #expect(AvatarLibraryRules.copyName(of: "  Renard\nroux") == "Renard (copy)")
    #expect(AvatarLibraryRules.copyName(of: " ") == "Avatar (copy)")
  }

  @Test("20 avatars at most, drafts included: no 21st is created, and nothing changes")
  func limit() throws {
    var index = AvatarLibraryIndex()
    for number in 0..<AvatarLibraryRules.maximumCount {
      let date = Date(timeIntervalSince1970: Double(number))
      if number.isMultiple(of: 2) {
        try index.addCopy(UUID(), at: date)
      } else {
        try index.addDraft(UUID(), basedOn: nil, at: date)
      }
    }
    #expect(!index.canCreate)
    let before = index
    #expect(throws: AvatarLibraryError.limitReached) { try index.addCopy(UUID(), at: .now) }
    #expect(index == before)
  }

  @Test("Deleting the avatar in use gives the panel back the default one")
  func removeInUse() throws {
    let id = UUID()
    var index = AvatarLibraryIndex()
    try index.addCopy(id, at: .now)
    try index.setInUse(.stored(id))
    try index.remove(.stored(id))
    #expect(index.inUse == .default)
    #expect(index.records.isEmpty)
  }

  @Test("The default avatar is not deleted or kept as a draft")
  func defaultIsFixed() throws {
    var index = AvatarLibraryIndex()
    #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) { try index.remove(.default) }
    #expect(throws: AvatarLibraryError.defaultAvatarIsFixed) {
      _ = try index.keep(.default, missing: [])
    }
  }

  @Test("A draft is not used before it is kept, and an index read from disk cannot say otherwise")
  func draftNotUsed() throws {
    let id = UUID()
    var index = AvatarLibraryIndex()
    try index.addDraft(id, basedOn: nil, at: .now)
    #expect(throws: AvatarLibraryError.notKept) { try index.setInUse(.stored(id)) }
    let read = AvatarLibraryIndex(
      inUse: .stored(id), records: [.init(id: id, state: .draft(basedOn: nil), addedAt: .now)])
    #expect(read.inUse == .default)
    let orphan = AvatarLibraryIndex(inUse: .stored(UUID()), records: [])
    #expect(orphan.inUse == .default)
  }

  @Test("library.json reads back as it was written, to the millisecond")
  func indexRoundTrip() throws {
    let kept = UUID()
    let draft = UUID()
    var index = AvatarLibraryIndex()
    try index.addCopy(kept, at: Date(timeIntervalSince1970: 1_790_000_000.125))
    try index.addDraft(
      draft, basedOn: .stored(kept), at: Date(timeIntervalSince1970: 1_790_000_001))
    try index.setInUse(.stored(kept))
    let data = try JSONEncoder().encode(index)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["format"] as? Int == 1)
    #expect(json["inUse"] as? String == kept.uuidString)
    let entries = try #require(json["entries"] as? [[String: Any]])
    #expect(entries.map { $0["state"] as? String } == ["kept", "draft"])
    #expect(entries[1]["basedOn"] as? String == kept.uuidString)
    #expect(entries[0]["addedAt"] as? String == "2026-09-21T14:13:20.125Z")
    #expect(try JSONDecoder().decode(AvatarLibraryIndex.self, from: data) == index)
  }

  @Test("An index read from disk is made consistent: each avatar once, drafts on kept avatars only")
  func indexConsistency() throws {
    let kept = UUID()
    let draft = UUID()
    let orphan = UUID()
    let json = """
      { "format": 1, "inUse": "\(draft.uuidString)", "entries": [
        { "id": "\(kept.uuidString)", "state": "kept", "addedAt": "2026-09-21T14:13:20.000Z" },
        { "id": "\(kept.uuidString)", "state": "draft" },
        { "id": "\(draft.uuidString)", "state": "draft", "basedOn": "\(kept.uuidString)" },
        { "id": "\(orphan.uuidString)", "state": "draft", "basedOn": "\(draft.uuidString)" } ] }
      """
    let index = try JSONDecoder().decode(AvatarLibraryIndex.self, from: Data(json.utf8))
    #expect(index.records.map(\.id) == [kept, draft, orphan])
    #expect(index.record(kept)?.state == .kept)
    #expect(index.record(draft)?.state == .draft(basedOn: .stored(kept)))
    #expect(index.record(orphan)?.state == .draft(basedOn: nil))
    #expect(index.record(draft)?.addedAt == .distantPast)
    #expect(index.inUse == .default)
  }

  @Test("An index of a later version is not read: the folders will say what there is")
  func laterIndex() {
    let json = #"{ "format": 2, "inUse": "default", "entries": [] }"#
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AvatarLibraryIndex.self, from: Data(json.utf8))
    }
  }
}
