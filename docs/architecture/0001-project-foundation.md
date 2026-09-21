# ADR 0001: Project foundation

- Status: Accepted
- Date: 2026-09-21
- Decision owners: Vibe Manager maintainers
- Related issue: [#1](https://github.com/hadrienl/vibe-manager/issues/1)

## Context

Vibe Manager is a native macOS workspace for supervising several coding-agent sessions. It
will coordinate interactive terminal processes, persistent session metadata and Git worktrees
across multiple repositories. Those responsibilities combine UI state, long-running streams and
filesystem access, so their boundaries must be explicit before product features are added.

## Decision

The product is a SwiftUI application targeting macOS 14 and later, built in Swift 6 with strict
concurrency checking. The Xcode application target is only a composition root. Product code lives
in a local Swift package split into modules:

- `VibeDomain` contains pure business types.
- `VibeApplication` contains use cases and abstract service ports.
- `VibePersistence`, `VibeAgents`, `VibeTerminal` and `VibeGit` implement infrastructure ports.
- `VibeUI` contains SwiftUI views and presentation state.

Dependencies point inwards: infrastructure and UI can depend on application and domain modules;
the reverse is forbidden. Cross-module runtime dependencies are injected by `AppEnvironment`.
UI state uses Observation and is isolated to the main actor. Mutable infrastructure services use
actors and expose asynchronous APIs.

The V1 is distributed directly rather than through the Mac App Store. App Sandbox remains off
because the core use case requires launching user-installed executables and accessing arbitrary
user-selected repositories. Entitlements will be added only when a documented capability needs
them. Release hardening, signing and notarization are handled by issue #19.

## Consequences

- Domain and application tests do not need to launch the app or touch the filesystem.
- Provider, terminal, Git and persistence implementations can evolve independently behind ports.
- The extra module boundaries add some initial files and build targets.
- Care is required to avoid leaking implementation-specific types through application protocols.
- Mac App Store distribution is not a V1 option without redesigning process and filesystem access.

## Rejected alternatives

- A single application target was rejected because it would not enforce the boundaries needed for
  concurrent process, persistence and Git work.
- A third-party dependency-injection framework was rejected as unnecessary for the V1.
- App Sandbox was rejected for the direct-distribution V1 because it conflicts with arbitrary CLI
  and repository access.
- Selecting a database in this decision was rejected; issue #2 will evaluate persistence behind
  the `SessionRepository` port.

