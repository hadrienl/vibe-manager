# 0024 — Sessions as tasks

- Status: accepted
- Date: 2026-09-25
- Issue: [#80](https://github.com/hadrienl/vibe-manager/issues/80)

## Context

The sidebar split the sessions on their process: Active when an agent ran, Closed when it did not
(ADR 0009). In practice the sessions are used as a task list — prepared, worked on, waiting on a
review or a build, finished — and whether an agent runs says nothing about any of that. A task
waiting on a review may keep its agent running; one paused for the night is still in progress.

## Decisions

### Two axes, never folded into one

`SessionStatus` keeps saying what the process does: `active`, `closed`, `archived`. Beside it,
`WorkSession.taskStatus` (`SessionTaskStatus`) says where the work stands: `todo`, `doing`,
`waiting`, `done`, `archived`. Neither is derived from the other at run time.

Archived is the one value they share, and `WorkSession` keeps it true:
`taskStatus == .archived` exactly when `status == .archived`. `setTaskStatus` refuses to enter or
leave `archived`; `archive(at:)` and `restore(at:)` are the only moves that do, because they stop
or release a process (ADR 0009). An unarchived session comes back in Done. `validate()` rejects a
session archived on one axis only.

### No transition the user did not ask for

The agent never moves a task. An agent waiting for an answer is not a task In Waiting — that is
#45's orange, on the row and on the tab that hides it — and an agent that stops has not finished
the task. Closing a session (⌘W) stops its agent and leaves the session in its column.

Three transitions follow from a command, and only those:

- Archive → Archived, Unarchive → Done.
- Starting a session that never ran, or restarting one, moves To Do and Done to In Progress
  (`ChangeTaskStatus.beginWork`, called by `SessionLauncher` for every launch the user asked for).
  A session in Waiting stays there. A restoration after a relaunch (#11) moves nothing: it brings
  back what was running, where it was.
- Moving a session that never ran to In Progress starts its agent with its prompt. To Do is where
  a task waits to be launched; the New Session sheet can put one there without starting it.

### The store moves to v6

`taskStatus` is written by schema v6; v5 is the session's ticket (ADR 0023). A v4 or v5 document is
read with the status its lifecycle implies — running is In Progress, never started is To Do, stopped
is Done, archived is Archived — and is rewritten in v6. A status this build does not know, or one that contradicts the lifecycle on
Archived, is read from the lifecycle instead of failing the whole store. The saved layout reads the
old `scope` the same way: Active becomes In Progress, Closed becomes Done.

### Columns, and a swipe that only reveals

The sidebar shows one column at a time behind four tabs, each with its colour, its symbol and its
count; Archived is reached from a line at its foot. Orange is kept out of the palette: it already
means "the agent waits for you".

A horizontal swipe on a row reveals the statuses before or after the current one, nearest first,
and nothing changes until a button is clicked — a trackpad makes the gesture too easily for it to
be the decision. Archive is offered only from Done. The swipe is taken from a local
`scrollWheel` monitor, and only for a gesture that starts horizontal over a row, the way Mail tells
a swipe from a scroll; its inertia is swallowed. Its arithmetic lives in `SessionSwipe`, a value
the tests exercise without an event.

During the gesture only the swiped row moves, aside, to uncover its buttons; the rest of the
column stays still. After a change the column on screen stays, and the selection passes to the row
that took the session's place: sorting a column is going down it. A first design slid the columns
around a still row; tried in the application, it read as noise, and was dropped.

This amends ADR 0009's "Two scopes": the tabs are no longer split on the process.
