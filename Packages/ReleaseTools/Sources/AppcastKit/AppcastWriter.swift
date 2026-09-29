import Foundation

/// Writes the feed. The same entries always give the same bytes, so that an unchanged feed
/// publishes an unchanged file.
enum AppcastWriter {
  static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
  static let vibeNamespace = "https://hadrienl.github.io/vibe-manager/xml-namespaces/vibe"
  static let feedURL = "https://hadrienl.github.io/vibe-manager/appcast.xml"

  static func xml(for entries: [AppcastEntry]) -> String {
    var lines = [
      #"<?xml version="1.0" encoding="utf-8"?>"#,
      #"<rss version="2.0" xmlns:sparkle="\#(sparkleNamespace)" xmlns:vibe="\#(vibeNamespace)">"#,
      "  <channel>",
      "    <title>Vibe Manager</title>",
      "    <link>\(escaped(feedURL))</link>",
      "    <language>en</language>",
    ]
    for entry in entries {
      lines += item(for: entry).map { "    " + $0 }
    }
    lines += ["  </channel>", "</rss>"]
    return lines.joined(separator: "\n") + "\n"
  }

  private static func item(for entry: AppcastEntry) -> [String] {
    let release = entry.release
    let item = entry.item
    var lines = [
      "<item>",
      "  <title>\(escaped("Vibe Manager \(item.version)"))</title>",
      "  <link>\(escaped(release.htmlURL))</link>",
      "  <sparkle:version>\(entry.build.description)</sparkle:version>",
      "  <sparkle:shortVersionString>\(escaped(item.version))</sparkle:shortVersionString>",
    ]
    if let channel = entry.channel {
      lines.append("  <sparkle:channel>\(channel)</sparkle:channel>")
    }
    lines += [
      "  <sparkle:minimumSystemVersion>\(escaped(item.minimumSystemVersion))"
        + "</sparkle:minimumSystemVersion>",
      "  <vibe:hostProtocol>\(item.hostProtocol)</vibe:hostProtocol>",
      "  <sparkle:fullReleaseNotesLink>\(escaped(release.htmlURL))</sparkle:fullReleaseNotesLink>",
    ]
    if let publishedAt = release.publishedAt, let date = date(publishedAt) {
      lines.append("  <pubDate>\(rfc822(date))</pubDate>")
    }
    if let notes = release.body.flatMap(ReleaseNotes.html(of:)) {
      lines.append("  <description>\(cdata(notes))</description>")
    } else {
      lines.append(
        "  <sparkle:releaseNotesLink>\(escaped(release.htmlURL))</sparkle:releaseNotesLink>")
    }
    lines += [
      "  <enclosure url=\"\(escaped(entry.archiveURL))\" length=\"\(item.length)\""
        + " type=\"application/octet-stream\""
        + " sparkle:edSignature=\"\(escaped(item.edSignature))\"/>",
      "</item>",
    ]
    return lines
  }

  /// Escapes text and attribute values alike.
  static func escaped(_ text: String) -> String {
    HTML.escapingAttribute(text)
  }

  /// A CDATA section cannot hold `]]>`: it is closed before the `>` and a new one opened.
  static func cdata(_ text: String) -> String {
    "<![CDATA[" + text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
  }

  static func date(_ iso8601: String) -> Date? {
    ISO8601DateFormatter().date(from: iso8601)
  }

  static func rfc822(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }
}
