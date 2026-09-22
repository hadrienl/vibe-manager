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
mock provider is never registered on its own: set `VIBE_ENABLE_MOCK_AGENT` to list it, in any
configuration.

Sessions are created from a validated draft, then persisted, published and launched in that
order. The rules of that sequence — why Cancel creates nothing, why a failed launch keeps the
session, and why a model is optional — are documented in
[`docs/architecture/0007-session-creation.md`](docs/architecture/0007-session-creation.md).

Sessions are then worked in from a three-column workspace: the sessions on the left, the selected
terminal in the middle, the context of that session on the right. Changing session changes what
is shown and nothing else — no process is restarted and no scrollback is lost. The layout, the
folding thresholds of the columns and what is restored at launch are documented in
[`docs/architecture/0008-workspace-layout.md`](docs/architecture/0008-workspace-layout.md).

Nothing leaves that list on its own. Closing a session stops its agent and keeps everything else,
terminal output included; archiving asks once, detaches the process and marks the session as no
longer reopenable until it is unarchived. The sidebar has two tabs — Active and Closed — split on
whether an agent is running, not on whether a session was archived, so all past work is found in
one place. No session is ever deleted, and the list is searchable, filterable and sorted in an
order that survives a relaunch. The rules are documented in
[`docs/architecture/0009-session-history-and-archive.md`](docs/architecture/0009-session-history-and-archive.md).

Two real agents ship with the application, each documented with the choices its CLI forced:
[`docs/architecture/0005-codex-provider.md`](docs/architecture/0005-codex-provider.md) and
[`docs/architecture/0006-claude-code-provider.md`](docs/architecture/0006-claude-code-provider.md).
Neither reads a credential, injects an API key, or passes a flag that lowers the permissions the
user configured for their own CLI.

## Configuration

Shared, Debug and Release build settings live in `Configuration/*.xcconfig`. Local signing
identities and team IDs must be supplied through Xcode user settings or an untracked local override;
never commit them. The V1 is intended for direct distribution and does not enable App Sandbox.
