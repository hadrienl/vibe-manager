# Vibe Manager

Vibe Manager is a native macOS application for running several coding-agent sessions while keeping
their terminals, repositories and tasks organized in one place.

The application launches a SwiftUI state backed by an atomic, versioned local session store.
Claude Code and Codex run in real terminals, and a session can span several repositories, each in
a worktree of its own on one shared branch. Live Git status is tracked as a separate V1 issue.

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

The session sheet proposes no working folder: it is always chosen through the open panel, which is
also what grants access to it. Before the first run, copy `Configuration/Local.xcconfig.example` to
`Configuration/Local.xcconfig` and put your own `DEVELOPMENT_TEAM` in it. That file is not
versioned, and it is not cosmetic: without it Xcode signs the application ad hoc, macOS then
identifies it by a hash that changes at every build, and every privacy permission granted — Full
Disk Access included — is asked for again after the next compilation. See
[`docs/architecture/0010-file-access-permissions.md`](docs/architecture/0010-file-access-permissions.md).

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

A closed session goes back to work with one command. When the agent can resume its own
conversation, it does, and it is handed no prompt; when it cannot — no identifier was ever kept,
or the CLI would refuse the one that was — the application says so and offers a new process with a
summary of what the session carries, shown and editable before it is sent. The plan is rebuilt from
the stored session, so the same agent, model, folder and worktree come back untouched, and a
restart that fails leaves the session closed with everything it had. The three modes, the summary,
the locks against a double launch and what happens when a resumed conversation turns out to be gone
are documented in
[`docs/architecture/0010-session-restart.md`](docs/architecture/0010-session-restart.md).

Quitting is not a way to lose a day of context. On the way out, every running session is stopped,
closed in the store and left behind as the intention to resume it; at the next launch those
sessions come back with their provider's own resume, and nothing is asked again. A session the
store still calls running is closed before the first list is drawn, because nothing can be running
when the application has just started — and that state is how an unexpected stop is recognised. A
crash is not an intention, so it offers the sessions instead of taking them; a second copy of the
application is named and nothing is touched; a leftover process is signalled only when its
identity is confirmed. The sessions come back one at a time, with progress and a way to cancel that
stops nothing already running, and a restoration that sends a text to an agent is never automatic.
The runtime document, the four verdicts and the bounded exit are documented in
[`docs/architecture/0011-session-restoration.md`](docs/architecture/0011-session-restoration.md).

A session is one branch. Its slug is derived from its title once, editable before creation, and
never recomputed — renaming a session never renames `vibe/<slug>`. Each Git repository attached to
it gets a worktree on that branch under `~/VibeManager/Worktrees/<slug>/` (the root is a setting),
unless it is attached in place or is a plain folder. Every repository is read and planned before
anything is written, and each conflict — a branch already checked out, a stale record, a bare
repository — blocks only its own repository, with a remedy and, when it helps, a command to copy.
The agent starts in the main repository and is handed the others with `--add-dir`; the convention
opens its first prompt, and is shown in the sheet before it is sent. Vibe Manager creates
worktrees and branches and never deletes one: detaching, closing and archiving forget, and offer
the cleanup command instead. While an agent works, the inspector reports what it did to the
branches of each repository since the session started — created, moved, rewritten, deleted, and
what is uncommitted — read every 30 seconds for the session on screen only. The store moved to schema v3, where earlier sessions became
repositories attached in place. The decisions are documented in
[`docs/architecture/0012-multi-repository-worktrees.md`](docs/architecture/0012-multi-repository-worktrees.md).

The agents run as children of the application, so macOS asks *the application* for permission
whenever one of them reads a protected folder. That question is asked once, at launch, as a single
step explaining Full Disk Access and opening the right pane of System Settings — never in the
middle of creating a session. Refusing is a working answer: repositories are rarely in a protected
location, nothing is disabled, and the question stays reachable in Settings. The detection, the
build signature it depends on, and what the application deliberately does not do are documented in
[`docs/architecture/0010-file-access-permissions.md`](docs/architecture/0010-file-access-permissions.md).

Two real agents ship with the application, each documented with the choices its CLI forced:
[`docs/architecture/0005-codex-provider.md`](docs/architecture/0005-codex-provider.md) and
[`docs/architecture/0006-claude-code-provider.md`](docs/architecture/0006-claude-code-provider.md).
Neither reads a credential, injects an API key, or passes a flag that lowers the permissions the
user configured for their own CLI.

## Configuration

Shared, Debug and Release build settings live in `Configuration/*.xcconfig`. Local signing
identities and team IDs are supplied through `Configuration/Local.xcconfig`, which
`Shared.xcconfig` includes when it exists and which is never committed. The V1 is intended for direct distribution and does not enable App Sandbox.
