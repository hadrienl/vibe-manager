# ADR 0004: Terminal pseudo terminals and process supervision

- Status: Accepted
- Date: 2026-09-21
- Decision owners: Vibe Manager maintainers
- Related issue: [#4](https://github.com/hadrienl/vibe-manager/issues/4)

## Context

A work session is useless without a real interactive terminal: coding agents expect a controlling
terminal, colours, a window size and a readable standard input. Vibe Manager must run several of
them at once, present their output without freezing the interface, report their outcome, and stop
their whole process tree when a session is closed or the application quits.

Terminal emulation and process supervision are two different problems. The first is a large,
well-understood specification. The second is where the product requirements live: no orphaned
process, bounded memory, isolated streams, actionable launch failures.

## Decision

`VibeApplication` owns the ports and the values: `TerminalSpec`, `TerminalEvent`,
`TerminalProcessState`, `TerminalError`, `TerminalAttachment`, `TerminalSession` and
`TerminalSupervisor`. `VibeTerminal` implements them. `VibeDomain` learns nothing about
terminals, and no process API crosses into the application or the domain.

One actor per session, held by a supervisor actor keyed by `SessionID`. Two sessions share no
mutable state, so interleaved output is structurally impossible rather than a discipline.

A session is started with `posix_openpt`, `grantpt` and `unlockpt`. The parent opens the slave
once to apply the initial window size — Darwin rejects window-size ioctls on a master whose slave
has never been opened — then closes it after spawning. The child is created with `posix_spawn`,
with `POSIX_SPAWN_SETSID` so it leads a new session, file actions that open the slave *path* on
descriptor 0 and duplicate it onto 1 and 2 so it acquires a controlling terminal, and
`POSIX_SPAWN_CLOEXEC_DEFAULT` so no other descriptor — including the master of another session —
leaks into it. `posix_spawn` reports the failure of the exec itself, so a missing, unreadable or
non-runnable binary is distinguishable from a process that started and exited immediately.

Output travels as bytes. A pseudo terminal read cuts at an arbitrary offset, so decoding each
chunk as text would corrupt every multi-byte character and escape sequence straddling two reads.
A `DispatchSource` reads off the main actor, coalesces bursts into 16 ms windows, and applies back
pressure by suspending itself rather than growing a buffer: a suspended reader fills the kernel
buffer and blocks the writing process, which is the only back pressure that does not consume
unbounded memory. Writes use their own queue, because sharing the read queue would let a full
input buffer stall the reader and deadlock a child that cannot drain its own output.

Each session keeps a bounded replay buffer, limited by lines and by bytes, stored as the blocks in
which output was read so that trimming drops whole blocks instead of copying megabytes. A late
attachment receives the backlog and the live stream as one value, so nothing is lost between two
calls. Terminal output is never persisted: ADR 0002 deliberately excludes transcripts from the
session store.

The exit status comes from a process source and `waitpid`, never from the end of the stream: the
reader is given a bounded drain window after the process exits so that the last lines — the ones
that explain a failure — are delivered. Stopping sends `SIGTERM` to the process *group*, waits for
the grace period, then sends `SIGKILL` to the group; the master descriptor is closed last. An
`atexit` sweep kills the registered process groups, because a crash would otherwise leave agents
running with no window to observe them.

The environment is an explicit allowlist plus `TERM`, `COLORTERM`, `TERM_PROGRAM` and a locale.
No terminal byte is ever logged.

## Consequences

- A session owns its descriptors, its process group and its history; closing it releases all three.
- Sustained output bounds memory and never blocks the main actor, at the cost of throttling the
  emitting process — the deliberate trade-off.
- Launch failures carry a typed cause, a message and a remediation instead of an opaque exit code.
- The whole engine is testable with system binaries and shell scripts, without any agent CLI.
- Attaching after a burst replays a truncated history; the truncation is reported, not hidden.
- Multi-process coordination is out of scope: a terminal does not survive the application.

## Rejected alternatives

- SwiftTerm's `LocalProcess` was rejected: it would own the spawn and the teardown, which is
  exactly where this issue's requirements live.
- `fork` followed by `login_tty` was rejected because forking a multi-threaded process and running
  Swift code in the child is unsafe; `posix_spawn` covers the same need atomically.
- Decoding output into `String` at the boundary was rejected because reads split multi-byte
  sequences.
- An elastic buffer was rejected: it converts a fast producer into unbounded memory growth.
- Killing only the direct child was rejected: agents spawn their own children, which would survive.
- Persisting transcripts was rejected as out of scope and incompatible with the session store.
