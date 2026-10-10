// swift-tools-version: 6.0

import PackageDescription

// The mobile companion of #347: what the Mac and the iPhone share. Nothing of VibeManagerKit: the
// iOS application links it, and the application's own binary only links the wire, so that
// CloudKit stays out of it (ADR 0021).
let package = Package(
  name: "CompanionKit",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "CompanionCore", targets: ["CompanionCore"]),
    .library(name: "CompanionWire", targets: ["CompanionWire"]),
    .library(name: "CompanionKit", targets: ["CompanionKit"]),
  ],
  targets: [
    // The records and the rules read from them, as plain values: no CloudKit, no socket.
    .target(name: "CompanionCore"),
    // The link between the application and its companion agent, on a Unix socket of the Mac:
    // frames, messages and the check of the other end's signature.
    .target(name: "CompanionWire", dependencies: ["CompanionCore"]),
    // The records in CloudKit, and the sync engine that carries them (CKSyncEngine).
    .target(name: "CompanionKit", dependencies: ["CompanionCore"]),
    .testTarget(
      name: "CompanionKitTests", dependencies: ["CompanionCore", "CompanionWire", "CompanionKit"]),
  ]
)
