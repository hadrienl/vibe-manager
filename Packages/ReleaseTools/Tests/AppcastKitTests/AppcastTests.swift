import Foundation
import Testing

@testable import AppcastKit

@Suite("Appcast generation")
struct AppcastTests {
  private static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

  private func generate(_ directory: String = "") throws -> Appcast.Result {
    let root = Self.fixtures.appendingPathComponent(directory)
    return try Appcast.generate(
      releasesJSON: Data(contentsOf: root.appendingPathComponent("releases.json")),
      items: AppcastItem.files(in: root.appendingPathComponent("items"))
    )
  }

  @Test("The feed of the fixtures is the golden file, byte for byte")
  func matchesGoldenFile() throws {
    let expected = try String(
      contentsOf: Self.fixtures.appendingPathComponent("appcast.xml"), encoding: .utf8)

    #expect(try generate().xml == expected)
  }

  @Test("The same releases give the same bytes, in whatever order they come")
  func isDeterministic() throws {
    let root = Self.fixtures
    let releases = try GitHubRelease.decodeList(
      from: Data(contentsOf: root.appendingPathComponent("releases.json")))
    let items = try AppcastItem.files(in: root.appendingPathComponent("items"))

    let forward = try Appcast.generate(releases: releases, items: items).xml
    let backward = try Appcast.generate(releases: releases.reversed(), items: items).xml

    #expect(forward == backward)
  }

  @Test("A draft is never in the feed, even with its archive and its item")
  func excludesDrafts() throws {
    let result = try generate()

    #expect(!result.entries.contains { $0.release.draft })
    #expect(!result.xml.contains("1.2.0"))
    #expect(!result.xml.contains("untagged"))
    // Left out without a word: a draft is not a release the feed ever considers.
    #expect(!result.skipped.contains { $0.contains("v1.2.0") })
  }

  @Test("A release without its .zip or without its item is left out, and said so")
  func skipsIncompleteReleases() throws {
    let result = try generate()

    #expect(result.entries.map(\.item.version) == ["1.1.0", "1.1.0-rc.10", "1.1.0-rc.9", "1.0.0"])
    #expect(
      result.skipped == [
        "v1.0.0-rc.2: no asset VibeManager-1.0.0-rc.2.zip, left out",
        "v1.0.0-rc.1: no appcast item, left out",
      ])
  }

  @Test("A prerelease is on the unstable channel, a final version on none")
  func channels() throws {
    let result = try generate()

    let channels = Dictionary(
      uniqueKeysWithValues: result.entries.map { ($0.item.version, $0.channel) })
    #expect(channels["1.1.0-rc.10"] == "unstable")
    #expect(channels["1.1.0-rc.9"] == "unstable")
    #expect(channels["1.1.0"] == .some(nil))
    #expect(channels["1.0.0"] == .some(nil))
    #expect(!result.xml.contains("<sparkle:channel>beta"))
  }

  @Test("An item whose length is not the size of the asset is an error")
  func rejectsLengthMismatch() throws {
    #expect(
      throws: AppcastError.lengthMismatch(
        tag: "v1.1.0", archive: "VibeManager-1.1.0.zip", length: 41_000_000, size: 40_999_998)
    ) {
      try generate("mismatch")
    }
  }

  @Test("An item attached to another version's release is an error")
  func rejectsTagMismatch() throws {
    let release = Self.release(tag: "v1.1.1", size: 10)
    let item = Self.item(version: "1.1.0", build: 1, length: 10)

    #expect(throws: AppcastError.tagMismatch(tag: "v1.1.1", version: "1.1.0")) {
      try Appcast.generate(releases: [release], items: ["v1.1.1": item])
    }
  }

  @Test("At most ten versions of each channel, the most recent ones")
  func keepsTenPerChannel() throws {
    var releases: [GitHubRelease] = []
    var items: [String: Data] = [:]
    for minor in 0..<15 {
      for (version, prerelease) in [("1.\(minor).0-rc.1", true), ("1.\(minor).0", false)] {
        let tag = "v\(version)"
        releases.append(Self.release(tag: tag, prerelease: prerelease, size: 10))
        items[tag] = Self.item(version: version, build: 100 + minor, length: 10)
      }
    }

    let entries = try Appcast.generate(releases: releases, items: items).entries

    #expect(entries.filter { $0.release.prerelease }.count == 10)
    #expect(entries.filter { !$0.release.prerelease }.count == 10)
    #expect(entries.first?.item.version == "1.14.0")
    #expect(entries.last?.item.version == "1.5.0-rc.1")
  }

  @Test("Sorted by build, then the final version before its candidates, rc.10 before rc.9")
  func sortsByBuildThenVersion() throws {
    let versions = [
      ("1.0.0-rc.9", 7), ("1.0.0", 7), ("1.0.0-rc.10", 7), ("0.9.0", 9), ("1.0.0-rc.2", 5),
    ]
    let releases = versions.map {
      Self.release(tag: "v\($0.0)", prerelease: $0.0.contains("-"), size: 10)
    }
    let items = Dictionary(
      uniqueKeysWithValues: versions.map {
        ("v\($0.0)", Self.item(version: $0.0, build: $0.1, length: 10))
      })

    let entries = try Appcast.generate(releases: releases, items: items).entries

    #expect(
      entries.map(\.item.version) == [
        "0.9.0", "1.0.0", "1.0.0-rc.10", "1.0.0-rc.9", "1.0.0-rc.2",
      ])
  }

  @Test("Releases come as pages from `gh api --paginate --slurp`, or as a plain list")
  func readsPagesAndPlainLists() throws {
    let release = """
      {"tag_name":"v1.0.0","draft":false,"prerelease":false,"html_url":"h",\
      "published_at":null,"body":null,"assets":[]}
      """
    let pages = Data("[[\(release)],[]]".utf8)
    let plain = Data("[\(release)]".utf8)

    #expect(try GitHubRelease.decodeList(from: pages).map(\.tagName) == ["v1.0.0"])
    #expect(try GitHubRelease.decodeList(from: plain).map(\.tagName) == ["v1.0.0"])
    #expect(throws: AppcastError.self) { try GitHubRelease.decodeList(from: Data("{}".utf8)) }
  }

  @Test("Text, URLs and signatures are escaped for XML")
  func escapesXML() throws {
    var release = Self.release(tag: "v1.0.0", size: 10)
    release.htmlURL = "https://example.com/?a=1&b=<2>"
    release.assets[0].browserDownloadURL = "https://example.com/a.zip?x=\"1\"&y=2"

    let xml = try Appcast.generate(
      releases: [release], items: ["v1.0.0": Self.item(version: "1.0.0", build: 1, length: 10)]
    ).xml

    #expect(xml.contains("<link>https://example.com/?a=1&amp;b=&lt;2&gt;</link>"))
    #expect(xml.contains(#"url="https://example.com/a.zip?x=&quot;1&quot;&amp;y=2""#))
    #expect(!xml.contains("b=<2>"))
  }

  private static func release(tag: String, prerelease: Bool = false, size: Int) -> GitHubRelease {
    let archive = "VibeManager-\(tag.dropFirst()).zip"
    return GitHubRelease(
      tagName: tag, draft: false, prerelease: prerelease,
      htmlURL: "https://github.com/hadrienl/vibe-manager/releases/tag/\(tag)",
      publishedAt: "2026-10-01T12:00:00Z", body: nil,
      assets: [
        .init(
          name: archive, size: size,
          browserDownloadURL: "https://github.com/hadrienl/vibe-manager/releases/download/\(tag)/"
            + archive)
      ])
  }

  private static func item(version: String, build: Int, length: Int) -> Data {
    Data(
      """
      {"version":"\(version)","build":"\(build)","archive":"VibeManager-\(version).zip",\
      "length":\(length),"edSignature":"c2lnbmF0dXJl","minimumSystemVersion":"14.0",\
      "hostProtocol":1}
      """.utf8)
  }
}
