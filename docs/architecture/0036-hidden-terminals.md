# ADR 0036: Terminals nobody looks at cost the main actor nothing

- Status: Accepted; amends [0004](0004-terminal-pty.md) and [0017](0017-terminal-host.md)
- Date: 2026-09-30
- Decision owners: Vibe Manager maintainers
- Related issue: [#248](https://github.com/hadrienl/vibe-manager/issues/248)

## Context

Every session keeps its terminal view mounted, hidden behind the one on screen (#8). Each block of
output an agent wrote woke the main actor five times: SwiftTerm parsed it into the hidden view, the
launcher noted when it arrived, the launch observer decoded it as text, and the exit watch and the
pane's status were both handed it only to throw it away. With twenty agents at work, that was the
main actor's largest cost, whatever the user was looking at.

Measured on SwiftTerm 1.20, parsing an agent's interface costs about 0.83 ms per 5.5 KB frame,
6.8 MB/s: the parse dominates, the hop to the main actor costs next to nothing. Batching the output of
hidden views would have cut the number of tasks and none of the work.

## Decision

**A subscriber says what it reads** (`TerminalEventInterest`): everything, the state only, or pulses —
told of output at once, then at most once per interval, and always once more after the last block of
a burst. The session's actor serves each one only that (`TerminalSubscribers`, shared by the local and
the hosted session), and notes the instant of the last output itself (`lastOutputAt()`).

- The exit watch and the pane's status read the state.
- The activity tracker and the side terminals read pulses every 250 ms; the tracker's loop runs off
  the main actor.
- The launch observer reads the output only if it says it does (`readsOutput`): never for Claude
  Code, and for Codex until it has its identifier (`AgentOutputDemand.enough`). It decodes off the
  main actor, then waits for the end on the state alone.

**A view put away is suspended.** Five seconds after it was hidden — long enough to step through
sessions without paying for it — its live feed is cancelled and it is fed nothing. The history the
session keeps anyway (ADR 0004) says where it starts in the stream (`startOffset`), and the view
remembers how far it was fed; shown again, it is fed only what follows, in 64 KB slices with a yield
between two, hidden until done and with « Updating the terminal… » past 150 ms. Every byte fed then is
new to the view, so it answers what they ask, exactly once. Output the history already let go of is
lost to the view, as it is to a view opened now.

**A suspended terminal still answers.** A sentinel reads a suspended view's output off the main actor
— no emulation, a few states that follow escape sequences across reads — for what SwiftTerm answers
(cursor position, attributes, modes, version, colours, settings, graphics, window size) and for the
folder a shell reports (OSC 7). When a sequence completes, the view catches up at once, still hidden,
answers from the exact state of its screen, and goes back to being fed nothing. Without it, Codex
started in the background would wait forever for the position of its cursor.

## Consequences

- Per block of output, the main actor is woken once when the view is on screen, and not at all when
  it has been put away, beyond four pulses a second for the side terminals.
- Coming back to a session costs a catch-up: nothing for a glance, up to about 600 ms for a full
  4 MiB history.
- The list of questions follows SwiftTerm: it is to be checked at each upgrade, against every call to
  `sendResponse`. A question it misses is answered when the view comes back.
- `lastOutputAt` no longer lives in the launcher, and has nothing to be purged of.

## Rejected alternatives

- Feeding hidden views in batches: the parse is the cost, not the number of feeds.
- Parsing off the main actor inside SwiftTerm: its view reads the buffer from the main thread to draw
  and for accessibility, without a lock.
- Suspending at once: stepping through sessions would catch up at every step.
- Unmounting the SwiftTerm views of sessions not shown recently (about 17 MB each): left to a ticket of
  its own.
