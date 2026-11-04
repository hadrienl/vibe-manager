// swift-tools-version: 6.0
// Probe (#study): which of VibeManagerKit's modules build with the Swift toolchain for Windows?
// It reuses their sources as they are, and leaves out the Apple-only dependencies of the real manifest.
import PackageDescription

let sources = "Sources"  // copied from ../VibeManagerKit/Sources by the workflow
let package = Package(
  name: "WindowsProbe",
  defaultLocalization: "en",
  targets: [
    .target(name: "VibeDomain", path: "\(sources)/VibeDomain"),
    .target(name: "VibeApplication", dependencies: ["VibeDomain"], path: "\(sources)/VibeApplication"),
    .target(name: "VibeProcess", path: "\(sources)/VibeProcess"),
    .target(name: "VibePersistence", dependencies: ["VibeApplication", "VibeDomain"], path: "\(sources)/VibePersistence"),
    .target(name: "VibeGit", dependencies: ["VibeApplication", "VibeDomain", "VibeProcess"], path: "\(sources)/VibeGit"),
    .target(name: "VibeAgents", dependencies: ["VibeApplication", "VibeDomain", "VibeProcess"], path: "\(sources)/VibeAgents"),
    .target(name: "VibeEndpoints", dependencies: ["VibeDomain", "VibeApplication"], path: "\(sources)/VibeEndpoints"),
  ]
)
