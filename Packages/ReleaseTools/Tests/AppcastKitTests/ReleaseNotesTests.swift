import Testing

@testable import AppcastKit

@Suite("Release notes")
struct ReleaseNotesTests {
  @Test("Only what comes before the checklist marker is published")
  func cutsAtMarker() {
    let body = "Faster startup.\r\n\r\n<!-- release-checklist -->\r\n- [x] Notarized in 4 min\r\n"

    #expect(ReleaseNotes.publicMarkdown(of: body) == "Faster startup.")
    #expect(ReleaseNotes.html(of: body) == "<p>Faster startup.</p>\n")
  }

  @Test("Without the marker, or with nothing before it, there are no notes")
  func noMarkerNoNotes() {
    #expect(ReleaseNotes.html(of: "Faster startup.\n- [x] Notarized in 4 min") == nil)
    #expect(ReleaseNotes.html(of: "\n<!-- release-checklist -->\n- [x] Notarized") == nil)
  }

  @Test("Text and code keep their `&` and `<` as text")
  func escapesText() throws {
    let html = try #require(
      ReleaseNotes.html(of: "Fish & chips, `a < b`, <b>bold</b>\n<!-- release-checklist -->"))

    #expect(html == "<p>Fish &amp; chips, <code>a &lt; b</code>, <b>bold</b></p>\n")
  }

  @Test("A CDATA section is cut around `]]>`")
  func splitsCDATA() {
    #expect(AppcastWriter.cdata("a]]>b") == "<![CDATA[a]]]]><![CDATA[>b]]>")
  }
}
