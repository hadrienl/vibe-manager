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
    .library(name: "VibeTerminalUI", targets: ["VibeTerminalUI"]),
    .library(name: "VibeUI", targets: ["VibeUI"]),
  ],
  dependencies: [
    // Pinned exactly: the emulator parses untrusted output, so its version is a deliberate
    // choice rather than whatever a range resolves to.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
  ],
  targets: [
    .target(name: "VibeDomain"),
    .target(name: "VibeApplication", dependencies: ["VibeDomain"]),
    .target(name: "VibePersistence", dependencies: ["VibeApplication", "VibeDomain"]),
    .target(
      name: "VibeAgents",
      dependencies: ["VibeApplication", "VibeDomain"],
      resources: [.copy("Resources/mock-agent.sh")]
    ),
    .target(name: "VibeTerminal", dependencies: ["VibeApplication", "VibeDomain"]),
    .target(name: "VibeGit", dependencies: ["VibeApplication", "VibeDomain"]),
    .target(
      name: "VibeTerminalUI",
      dependencies: [
        "VibeApplication", "VibeDomain", .product(name: "SwiftTerm", package: "SwiftTerm"),
      ]
    ),
    .target(
      name: "VibeUI",
      dependencies: ["VibeApplication", "VibeDomain", "VibeTerminalUI"]
    ),
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
      name: "VibeAgentsTests",
      // VibeTerminal is a test only dependency: the Codex integration test runs the launch
      // plan through the real supervisor, which is the only way to prove that no escaping
      // happens between a provider and a process.
      dependencies: ["VibeAgents", "VibeApplication", "VibeDomain", "VibeTerminal"]
    ),
    .testTarget(
      name: "VibeTerminalTests",
      dependencies: ["VibeTerminal", "VibeApplication", "VibeDomain"]
    ),
    .testTarget(
      name: "VibeTerminalUITests",
      dependencies: ["VibeTerminalUI", "VibeApplication", "VibeDomain"]
    ),
    .testTarget(
      name: "VibeUITests",
      dependencies: ["VibeUI", "VibeApplication", "VibeDomain"]
    ),
  ]
)
