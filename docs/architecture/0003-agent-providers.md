# 0003 — Agent providers and CLI detection

- Status: accepted
- Date: 2026-09-21
- Issue: [#3](https://github.com/hadrienl/vibe-manager/issues/3)

## Context

Vibe Manager has to drive Claude Code, Codex and future agents. Coupling the views or the
terminal to one executable would make every new agent a change in the UI, and would make the
launch logic untestable without a paid account.

## Decisions

### A provider describes a launch, it never starts one

`AgentProvider.launchPlan(for:)` returns an `AgentLaunchPlan` value: executable, `arguments`,
environment, working directory and prompt delivery. Creating the PTY belongs to #4. The plan is
deterministic, so golden tests cover the generated commands without spawning anything.

### Arguments are always an array

No command line is ever interpolated into a shell. Prompts and paths containing quotes,
newlines, `$(…)`, pipes or non ASCII characters are passed verbatim as separate `argv`
entries, which removes escaping bugs and shell injection by construction.

A prompt above `AgentPromptLimits.argumentByteLimit` (16 KiB) moves to the standard input, and
one above `maximumByteLimit` (1 MiB) is refused with a typed error rather than truncated.

### Detection has an explicit order

`userDefinedPath` → declared candidate directories → inherited `PATH` → login shell
`command -v`. An application launched from the Finder inherits the `PATH` of `launchd`, not the
one the user sees in their terminal, so `PATH` alone hides most Homebrew and version manager
installations. The login shell is only asked where the binary is; the agent itself is never run
by the locator.

The detection source is kept in `AgentInstallation` and shown in the diagnostic: it is what
explains to a user why the application sees a different binary than their terminal does.

### Availability is a state, not a boolean

`available`, `outdated`, `notFound`, `notExecutable`, `unauthenticated`, `probeFailed` each map
to a different message and remediation. An unreadable `--version` output keeps the agent
available with an unknown version: a CLI changing its output format must not disable it.

Authentication is detected at best, from the exit code of a command the provider declares. No
token, credential file or keychain item is ever read, and an unknown sign in state never blocks
a launch.

### Detection is cached, bounded and cancellable

`AgentAvailabilityProbe` is an actor. Concurrent callers share one in flight detection, results
expire after a short time to live, and `invalidate()` or a new user defined path clears them.
Every probe has a timeout and terminates, then kills, a command that hangs.

### A timeout is an absence of answer, not a diagnostic

A version probe that lapses is retried once, on the wider `versionRetryTimeout` budget, and only
the second silence produces `probeFailed(.timedOut)`. At first launch the binary is not in the
disk cache yet, the login shell may have been asked where it lives, and the application is still
starting: the usual budget lapses on installations that are perfectly fine, and the first screen
then declares a working agent broken. An exit code, a refusal to start and a cancellation are
answers, so none of them is retried.

### A ready agent is detected once, everything else is detected again

An agent found `available` is cached for the whole session: a CLI does not uninstall itself while
the application runs, so probing it again costs two processes per screen and buys nothing.

Every other state expires after a short `timeToLive`. Each of them is either an absence of answer
or a problem whose remediation the diagnostic just asked the user to go and perform in a terminal
— install, update, sign in — so it is precisely the state that must not survive their coming
back. Opening the sheet again is then enough to see the agent turn ready, without having to find
the detect button first. The delay exists only so that a redrawn window, or a sheet opened twice
in a row, does not spawn a process each time.

`invalidate()`, a new user defined path and an explicit detection still look again in every case,
`available` included.

`AgentProbeFailure.isTransient` carries that distinction into the presentation: a silent agent
reads as "did not answer in time" and offers to detect again first, while a failing one keeps
"could not be inspected" and the remediations that ask the user to go and fix something.

Serialising the startup probes was considered and refused: it turns one budget into one budget
per provider on a Mac where no agent is installed, to remove a contention that is not the cause.
Two short processes on a multiple core machine wait on the disk and on a runtime starting, not on
each other.

### The registry is the only place a provider is registered

`AgentProviderRegistry` keeps registration order, probes providers concurrently and answers
`AgentProviderResolving`, the port the use cases and `AppModel` depend on. An unknown
`providerID` read from a stored session resolves to `SessionAgentResolution.unknownProvider`:
the session loads and is simply not resumable.

### Privacy

Environments are built from an allow list (`AgentEnvironmentPolicy`), so an API key present in
the application environment never reaches an agent unless it is passed explicitly. Exported
diagnostics reduce paths to their parent directory with the home directory abbreviated, and
carry no prompt, token or environment dump.

### A mock provider ships with the app

`MockAgentProvider` runs a bundled `mock-agent.sh`, supports model selection, initial prompt and
resume, prints a resume identifier and can simulate every availability state. It is registered
in Debug builds only, so a distributed Release never lists it.

### Known limits, left open on purpose

- The login shell fallback runs `$SHELL -l -c`, which sources the user's rc files and therefore
  executes their own code inside the application. It is the only reliable way to see a `PATH`
  set by a version manager, and it never runs the agent binary itself, but it deserves a
  product decision before more providers rely on it.
- Terminating a timed out probe signals the direct child only. A login shell that spawned
  background children can leave them running. Moving probes to their own process group is the
  natural fix if it shows up in practice.
- The `PATH` discovered by the login shell is used to find the binary, not to launch the agent:
  a launched agent still inherits the application `PATH`, so an agent shelling out to `git` or
  `node` may not find them. Propagating the discovered `PATH` belongs to the launch work of #4.
- An agent that is uninstalled, downgraded or moved while the application runs keeps its
  `available` state until the user detects again; the launch then fails on the stale path with
  the CLI's own error. Detecting once was the point, and the button is the way back.
- A login shell lookup that lapses in `FileSystemExecutableLocator` still degrades to
  `notFound`, which reads as "was not found on this Mac" — as wrong as the timeout verdict this
  decision removes, but much rarer. The same reasoning applies to it the day it shows up.
- `AgentDiagnostic.redact(path:)` abbreviates against `NSHomeDirectory()`, which stops matching
  the day App Sandbox is enabled. Revisit it together with the sandboxing decision of #19.

## Consequences

- Adding Claude Code (#6) or Codex (#5) means writing a `CommandLineAgentSpecification` and a
  `CommandLineAgentArgumentBuilder`, then registering the provider in `AppEnvironment`.
- #4 consumes `AgentLaunchPlan` and is responsible for writing the prompt on the standard input
  when `promptDelivery` says so.
- #18 will fill the `reportsUsage` capability, which is only declared here.
- Storing a user defined executable path in the settings, and the provider pickers, belong to
  #7 and #8; the probe already accepts the path through `setUserDefinedPath(_:)`.
