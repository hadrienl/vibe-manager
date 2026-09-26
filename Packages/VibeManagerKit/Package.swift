// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "VibeManagerKit",
  // English is the development language, and the one a string falls back to when the catalog has
  // no translation for the user's language (docs/localization.md).
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "VibeDomain", targets: ["VibeDomain"]),
    .library(name: "VibeApplication", targets: ["VibeApplication"]),
    .library(name: "VibePersistence", targets: ["VibePersistence"]),
    .library(name: "VibeProcess", targets: ["VibeProcess"]),
    .library(name: "VibeAgents", targets: ["VibeAgents"]),
    .library(name: "VibeTerminal", targets: ["VibeTerminal"]),
    .library(name: "VibeGit", targets: ["VibeGit"]),
    .library(name: "VibeTerminalUI", targets: ["VibeTerminalUI"]),
    .library(name: "VibeBrowser", targets: ["VibeBrowser"]),
    .library(name: "VibeConversationUI", targets: ["VibeConversationUI"]),
    .library(name: "VibeUI", targets: ["VibeUI"]),
    .library(name: "VibeComposition", targets: ["VibeComposition"]),
  ],
  dependencies: [
    // Pinned exactly: the emulator parses untrusted output, so its version is a deliberate
    // choice rather than whatever a range resolves to.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    // Pinned exactly for the same reason: it parses what an agent wrote. 0.6.0 is the last release
    // whose manifest the Swift 6.1 of CI's Xcode 16.4 can read; later ones ask for tools 6.2.
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0"),
  ],
  targets: [
    // Every target whose text reaches the user carries its own string catalog.
    .target(name: "VibeDomain", resources: [.process("Localizable.xcstrings")]),
    .target(
      name: "VibeApplication",
      dependencies: ["VibeDomain"],
      resources: [.process("Localizable.xcstrings")]
    ),
    .target(
      name: "VibePersistence",
      dependencies: ["VibeApplication", "VibeDomain"],
      resources: [.process("Localizable.xcstrings")]
    ),
    // The one way to run a child that is not a terminal, and the guard that stops every child
    // group the application started when it exits. Depends on nothing: it is infrastructure.
    .target(name: "VibeProcess"),
    .target(
      name: "VibeAgents",
      dependencies: ["VibeApplication", "VibeDomain", "VibeProcess"],
      resources: [.copy("Resources/mock-agent.sh"), .process("Localizable.xcstrings")]
    ),
    .target(
      name: "VibeTerminal",
      dependencies: ["VibeApplication", "VibeDomain", "VibeProcess"],
      resources: [.process("Localizable.xcstrings")]
    ),
    .target(
      name: "VibeGit",
      dependencies: ["VibeApplication", "VibeDomain", "VibeProcess"],
      resources: [.process("Localizable.xcstrings")]
    ),
    .target(
      name: "VibeTerminalUI",
      dependencies: [
        "VibeApplication", "VibeDomain", .product(name: "SwiftTerm", package: "SwiftTerm"),
      ],
      resources: [.process("Localizable.xcstrings")]
    ),
    // The session's web view (#69): its tabs and their pages, and the channel through which an
    // agent drives them. WebKit and sockets; no view: the panel is drawn by VibeUI. It names no
    // user-facing sentence either — what it says is said to the agent, in English.
    .target(
      name: "VibeBrowser",
      dependencies: ["VibeApplication", "VibeDomain", "VibeProcess", "VibeTerminal"]
    ),
    // The conversation view of #38: Markdown, code and diffs drawn from a transcript. Its own
    // module, so that the Markdown parser stays out of everything else, as SwiftTerm does.
    .target(
      name: "VibeConversationUI",
      dependencies: [
        "VibeApplication", "VibeDomain", .product(name: "Markdown", package: "swift-markdown"),
      ],
      resources: [.process("Localizable.xcstrings")]
    ),
    .target(
      name: "VibeUI",
      dependencies: [
        "VibeApplication", "VibeBrowser", "VibeDomain", "VibeTerminalUI", "VibeConversationUI",
      ],
      resources: [.process("Localizable.xcstrings")]
    ),
    // The application, composed. Out of the application target so that a test can compose it.
    .target(
      name: "VibeComposition",
      dependencies: [
        "VibeAgents", "VibeApplication", "VibeBrowser", "VibeDomain", "VibeGit",
        "VibePersistence", "VibeProcess", "VibeTerminal", "VibeTerminalUI", "VibeConversationUI",
        "VibeUI",
      ]
    ),
    // The terminal host in a process of its own, for the tests that need one to outlive their
    // client or to be killed. The application runs the same code from its own binary.
    .executableTarget(
      name: "VibeTerminalHostFixture",
      dependencies: ["VibeTerminal", "VibeApplication", "VibePersistence"],
      path: "Tests/VibeTerminalHostFixture"
    ),
    // The web view's bridge in a process of its own (#69): the channel accepts a process by where
    // it descends from, which only a real child process can show.
    .executableTarget(
      name: "VibeBrowserBridgeFixture",
      dependencies: ["VibeBrowser", "VibeTerminal"],
      path: "Tests/VibeBrowserBridgeFixture"
    ),
    // Resolves a string in a given language, from the catalog of the module it belongs to.
    .target(name: "VibeLocalizationTesting", path: "Tests/VibeLocalizationTesting"),
    .testTarget(
      name: "VibeDomainTests", dependencies: ["VibeDomain", "VibeLocalizationTesting"]),
    .testTarget(name: "VibeProcessTests", dependencies: ["VibeProcess"]),
    .testTarget(
      name: "VibeApplicationTests",
      dependencies: ["VibeApplication", "VibeDomain", "VibeLocalizationTesting"]
    ),
    .testTarget(
      name: "VibePersistenceTests",
      // VibeProcess reads the diagnostics archive back with the system's `unzip`.
      dependencies: [
        "VibePersistence", "VibeApplication", "VibeDomain", "VibeProcess",
        "VibeLocalizationTesting",
      ]
    ),
    .testTarget(
      name: "VibeAgentsTests",
      // VibeTerminal is a test only dependency: the Codex integration test runs the launch
      // plan through the real supervisor, which is the only way to prove that no escaping
      // happens between a provider and a process.
      dependencies: ["VibeAgents", "VibeApplication", "VibeDomain", "VibeTerminal"]
    ),
    .testTarget(
      name: "VibeGitTests",
      dependencies: ["VibeGit", "VibeApplication", "VibeDomain"]
    ),
    .testTarget(
      name: "VibeTerminalTests",
      // The fixture is listed so that it is built before the tests that spawn it.
      dependencies: ["VibeTerminal", "VibeApplication", "VibeDomain", "VibeTerminalHostFixture"]
    ),
    .testTarget(
      name: "VibeTerminalUITests",
      dependencies: [
        "VibeTerminalUI", "VibeApplication", "VibeDomain", "VibeLocalizationTesting",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ]
    ),
    // The application composed for real — file store, runtime document, terminal host in a process
    // of its own, real Git repositories — driven the way the interface drives it (#19).
    .testTarget(
      name: "VibeScenarioTests",
      dependencies: [
        "VibeComposition", "VibeUI", "VibeApplication", "VibeDomain", "VibeAgents",
        "VibeTerminal", "VibeTerminalUI", "VibePersistence", "VibeGit", "VibeProcess",
        "VibeTerminalHostFixture", "VibeBrowser", "VibeBrowserBridgeFixture",
      ]
    ),
    .testTarget(
      name: "VibeBrowserTests",
      dependencies: [
        "VibeBrowser", "VibeApplication", "VibeDomain", "VibeProcess", "VibeTerminal",
        "VibeBrowserBridgeFixture",
      ]
    ),
    .testTarget(
      name: "VibeConversationUITests",
      dependencies: [
        "VibeConversationUI", "VibeApplication", "VibeDomain", "VibeLocalizationTesting",
      ]
    ),
    .testTarget(
      name: "VibeUITests",
      dependencies: [
        "VibeUI", "VibeApplication", "VibeDomain", "VibeTerminalUI", "VibeLocalizationTesting",
      ]
    ),
  ]
)
