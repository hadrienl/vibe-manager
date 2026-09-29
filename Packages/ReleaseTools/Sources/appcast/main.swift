import AppcastKit
import Foundation

// appcast --releases releases.json --items <directory> --output appcast.xml
//
// Writes the Sparkle feed of the published releases. `releases.json` is the output of
// `gh api --paginate --slurp repos/<owner>/<repository>/releases`; the directory holds the
// `.appcast.json` of each release, named `<tag>.json`.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("appcast: \(message)\n".utf8))
  exit(1)
}

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let name = arguments.popFirst() {
  guard ["--releases", "--items", "--output"].contains(name), let value = arguments.popFirst()
  else {
    fail("usage: appcast --releases <releases.json> --items <directory> --output <appcast.xml>")
  }
  options[name] = value
}
guard let releasesPath = options["--releases"], let itemsPath = options["--items"],
  let outputPath = options["--output"]
else {
  fail("usage: appcast --releases <releases.json> --items <directory> --output <appcast.xml>")
}

do {
  let releases = try Data(contentsOf: URL(fileURLWithPath: releasesPath))
  let items = try AppcastItem.files(in: URL(fileURLWithPath: itemsPath, isDirectory: true))
  let result = try Appcast.generate(releasesJSON: releases, items: items)
  for reason in result.skipped {
    FileHandle.standardError.write(Data("appcast: \(reason)\n".utf8))
  }
  try Data(result.xml.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  let versions = result.entries.map(\.item.version)
  print("appcast: \(versions.count) item(s) written to \(outputPath)", terminator: "")
  print(versions.isEmpty ? "" : ": " + versions.joined(separator: ", "))
} catch {
  fail(String(describing: error))
}
