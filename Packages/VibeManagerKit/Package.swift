// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "VibeManagerKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "VibeDomain", targets: ["VibeDomain"]),
    .library(name: "VibeApplication", targets: ["VibeApplication"]),
    .library(name: "VibePersistence", targets: ["VibePersistence"]),
    .library(name: "VibeAgents", targets: ["VibeAgents"]),
    .library(name: "VibeTerminal", targets: ["VibeTerminal"]),
    .library(name: "VibeGit", targets: ["VibeGit"]),
    .library(name: "VibeUI", targets: ["VibeUI"]),
  ],
  targets: [
    .target(name: "VibeDomain"),
    .target(name: "VibeApplication", dependencies: ["VibeDomain"]),
    .target(name: "VibePersistence", dependencies: ["VibeApplication", "VibeDomain"]),
    .target(name: "VibeAgents", dependencies: ["VibeApplication", "VibeDomain"]),
    .target(name: "VibeTerminal", dependencies: ["VibeApplication"]),
    .target(name: "VibeGit", dependencies: ["VibeApplication", "VibeDomain"]),
    .target(name: "VibeUI", dependencies: ["VibeApplication", "VibeDomain"]),
    .testTarget(name: "VibeDomainTests", dependencies: ["VibeDomain"]),
    .testTarget(
      name: "VibeApplicationTests",
      dependencies: ["VibeApplication", "VibeDomain"]
    ),
    .testTarget(
      name: "VibePersistenceTests",
      dependencies: ["VibePersistence", "VibeApplication", "VibeDomain"]
    ),
    .testTarget(
      name: "VibeUITests",
      dependencies: ["VibeUI", "VibeApplication", "VibeDomain"]
    ),
  ]
)
