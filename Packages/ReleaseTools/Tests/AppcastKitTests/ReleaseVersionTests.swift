import Testing

@testable import AppcastKit

@Suite("Release versions")
struct ReleaseVersionTests {
  @Test(
    "Versions are ordered as semver orders them",
    arguments: [
      ("1.0.0-rc.1", "1.0.0-rc.2"),
      ("1.0.0-rc.9", "1.0.0-rc.10"),
      ("1.0.0-rc.10", "1.0.0"),
      ("1.0.0", "1.0.1"),
      ("1.9.0", "1.10.0"),
      ("1.0.0-rc", "1.0.0-rc.1"),
      ("1.0.0-1", "1.0.0-rc"),
      ("1.0.0-alpha", "1.0.0-beta"),
    ])
  func orders(lower: String, higher: String) throws {
    let lower = try #require(ReleaseVersion(lower))
    let higher = try #require(ReleaseVersion(higher))

    #expect(lower < higher)
    #expect(!(higher < lower))
  }

  @Test(
    "What is not a semantic version is refused", arguments: ["1.0", "v1.0.0", "1.0.0-", "a.b.c"])
  func refuses(text: String) {
    #expect(ReleaseVersion(text) == nil)
  }
}

@Suite("Build numbers")
struct BuildNumberTests {
  @Test("A final version's .1 comes after its candidate and before the next commit")
  func order() throws {
    let candidate = try #require(BuildNumber("140"))
    let final = try #require(BuildNumber("140.1"))
    let next = try #require(BuildNumber("141"))
    #expect(candidate < final)
    #expect(final < next)
    #expect(try #require(BuildNumber("140.0")) == candidate)
    #expect(final.description == "140.1")
  }

  @Test("Anything else is not a build number")
  func invalid() {
    for text in ["", "1.", ".1", "1..2", "1a", "-1", "1.1-rc"] {
      #expect(BuildNumber(text) == nil, "\(text)")
    }
  }
}
