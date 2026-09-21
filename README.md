# Vibe Manager

Vibe Manager is a native macOS application for running several coding-agent sessions while keeping
their terminals, repositories and tasks organized in one place.

The application launches a SwiftUI state backed by an atomic, versioned local session store.
Claude, Codex, terminal and live Git integrations are tracked as separate V1 issues.

## Requirements

- macOS 14 or later
- Xcode 16.4 or later with the macOS SDK
- Swift 6

Xcode 27 and Swift 6.4 are used for local development. CI currently pins Xcode 16.4 so the project
does not accidentally adopt APIs newer than the documented baseline.

## Open and run

1. Open `VibeManager.xcodeproj` in Xcode.
2. Select the `VibeManager` scheme and the local Mac destination.
3. Run the application with Command-R.

No external package or secret is required for the foundation build.

## Build and test

Run the same checks as CI:

```sh
Scripts/ci.sh
```

Run only the package tests:

```sh
swift test --package-path Packages/VibeManagerKit
```

Build only the application without signing:

```sh
xcodebuild \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Architecture

The Xcode app target is a thin composition root. A local Swift package holds seven modules with
dependencies directed toward the application and domain layers. See
[`docs/architecture/0001-project-foundation.md`](docs/architecture/0001-project-foundation.md)
for the decision record and rationale.

Session metadata is stored in the user's Application Support directory. The format, migration,
backup and privacy decisions are documented in
[`docs/architecture/0002-session-persistence.md`](docs/architecture/0002-session-persistence.md).

Coding agents are reached through providers that only describe how to launch a CLI. Detection,
diagnostics, the registry and the built-in mock agent are documented in
[`docs/architecture/0003-agent-providers.md`](docs/architecture/0003-agent-providers.md). The
mock provider is registered in Debug builds; set `VIBE_DISABLE_MOCK_AGENT` to hide it, or
`VIBE_ENABLE_MOCK_AGENT` to expose it in a Release build.

## Configuration

Shared, Debug and Release build settings live in `Configuration/*.xcconfig`. Local signing
identities and team IDs must be supplied through Xcode user settings or an untracked local override;
never commit them. The V1 is intended for direct distribution and does not enable App Sandbox.
