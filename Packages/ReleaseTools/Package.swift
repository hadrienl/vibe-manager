// swift-tools-version: 6.0

import PackageDescription

// The tools that publish a release, apart from the application: they run in CI and on the
// maintainer's Mac, never in the application.
let package = Package(
  name: "ReleaseTools",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AppcastKit", targets: ["AppcastKit"]),
    .executable(name: "appcast", targets: ["appcast"]),
  ],
  dependencies: [
    // The same exact pin as VibeManagerKit: one version of the Markdown parser in the repository,
    // and 0.6.0 is the last release whose manifest the Swift 6.1 of Xcode 16.4 can read.
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0")
  ],
  targets: [
    // The Sparkle feed, computed from the published releases. No file and no network: the
    // executable reads the inputs and writes the result.
    .target(
      name: "AppcastKit",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")]
    ),
    .executableTarget(name: "appcast", dependencies: ["AppcastKit"]),
    .testTarget(
      name: "AppcastKitTests",
      dependencies: ["AppcastKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
