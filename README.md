# Vibe Manager

Vibe Manager is a native macOS application for running several coding-agent sessions while keeping
their terminals, repositories and tasks organized in one place.

The project is currently at its foundation stage. The application launches an empty SwiftUI state
backed by an in-memory session repository; Claude, Codex, terminal and Git integrations are tracked
as separate V1 issues.

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

## Configuration

Shared, Debug and Release build settings live in `Configuration/*.xcconfig`. Local signing
identities and team IDs must be supplied through Xcode user settings or an untracked local override;
never commit them. The V1 is intended for direct distribution and does not enable App Sandbox.

