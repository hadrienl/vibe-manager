# 0009 — Keeping the history, and archiving

- Status: accepted
- Date: 2026-09-22
- Issue: [#9](https://github.com/hadrienl/vibe-manager/issues/9)

## Context

The lifecycle was already modelled: ADR 0002 gave `SessionLifecycle` its three states and their
legal transitions, and #7 made creation write a session before anything is started. What was
missing is the other end — what happens when the work is done — and the promise attached to it:
**nothing disappears without a deliberate gesture, and no deliberate gesture destroys anything.**

Three verbs, three scopes, never conflated in the interface:

| Verb | Process | Data | Listed in |
|---|---|---|---|
| Close | stopped | entirely kept | current views |
| Archive | stopped, then detached | entirely kept | the Archived scope |
| Unarchive | untouched | entirely kept | current views |

There is no fourth verb. V1 deletes nothing: deciding what becomes of a session's worktrees (#12)
and of its usage record (#18) is a question this ticket has no business answering, and a store of
a few hundred sessions costs nothing to keep.

## Decisions

### The schema does not move

`SessionStatus.archived`, `closedAt` and `archivedAt` have been written by `StoredLifecycleV2`
since #2. A ticket about commands and views has no business invalidating a document, so the store
stays at schema v2 and every session archived by this release is readable by the previous one.

### Stopping comes before writing, always

`CloseSession` and `ArchiveSession` detach the process and only then record the new status. A
session written `archived` while its agent is still running would, if the application stopped
between the two, come back as an archived session with a live process nobody owns — and #11 would
find it in the store with no way to tell.

The order is not left to the reader: the tests assert it on an ordered log shared by the runtime
double and the repository double, so "detach, then save" is a fact rather than a reading of the
code.

### `SessionRuntime` is the seam

The panes, the agent observers and the output readers live in `VibeUI`; only they can guarantee
that nothing is left of a session. Naming that as a port in `VibeApplication` — two methods,
`detach` and `dispose` — lets the three use cases be tested without a terminal, a process or a
view, and keeps `VibeApplication` free of SwiftUI as before. `SessionLauncher` is its only real
implementation; `DetachedSessionRuntime` answers for a workspace that has no launcher at all.

### Archiving goes through closing

The domain keeps its strict invariant: `archive` is only legal from `closed`. A running session is
therefore archived in two recorded steps rather than one jump, which is why an archived session
always carries a real `closedAt` before its `archivedAt`. The order of events stays readable in
the store long after the fact, and the interface is the only place that knows the two steps are
one command.

### Closing keeps the pane; only archiving releases it

This amends ADR 0008, which unmounted the pane of a closed session as it did an archived one.
Reading what the agent said last **is** what "keep it in the history" means, so a closed session
keeps its `TerminalPaneModel`, read-only, with its scrollback. `dispose` — and only `dispose`, on
the archiving path — lets it go.

The scrollback itself lives in memory and is not persisted: the durable record of a session is its
notes (#16) and its metadata, not its terminal buffer.

### A process that ends on its own closes its session

An agent that exits, or crashes, takes the same path as the command: the launcher watches each
terminal's state and writes `closed` when it finishes. Without this, the session would stay stored
`active` with nothing behind it — the sidebar would keep calling it running, and #11 would try to
resume a conversation that has already ended.

### A stop that cannot be confirmed is said out loud

`PTYTerminalSession` escalates `SIGTERM` to `SIGKILL` and, when the process group still cannot be
reaped, releases its descriptors anyway. That last branch now finalizes as
`processOutcomeUnknown` rather than claiming a `terminated(SIGKILL)` nobody observed, and `detach`
reports `.unreachable(processIdentifier:)`.

The archive still goes through — the application has genuinely let go of everything it held — but
the workspace shows a banner naming the pid. Swallowing it would make "no process stays attached
to an archived session" a claim the code cannot support; refusing the archive would leave the user
hostage to a zombie.

### The filter is a value, and the order is total

`SessionFilter` — scope, sort, search text, agent and folder facets — is a pure value in
`VibeApplication` with an `apply(to:)` that the sidebar, the archive count and the tests all read.
Every ordering ends on the session identifier, so it is a **total** order: the same store and the
same filter draw the same list at every launch, which is the whole of "the order stays stable
after a restart".

`LoadSessions` still returns everything, archives included, and the filter is applied in
presentation. A store that filtered would need a second read path, and the number of sessions on a
developer's Mac does not justify a query.

### Filtering narrows the list, never the running work

Narrowing the sidebar changes which rows are drawn and nothing else: every pane stays mounted, so
searching for one session never stops another's agent or loses its scroll. The selection follows,
though — a session archived out of the current scope hands the selection to its neighbour rather
than leaving the detail column pointing at a row nobody can see.

### Scope and sort are remembered; the search text is not

The filter rides in `WorkspaceLayout`, in the user defaults, next to the columns and their widths:
how the user arranged their view is not a fact about the work, and `sessions.json` must not change
schema because someone sorted by name. `SessionFilter`'s own `Codable` conformance omits
`searchText` — a half-typed query found still applied three days later reads as a lost store, not
as a filter.

A facet that no longer names anything — an uninstalled agent, a folder with no sessions left — is
dropped at load. An empty sidebar with no visible reason is the failure mode worth designing out.

### Confirmation, and no undo stack

Archiving asks once, in a dialog that names the session, says that its running agent will be
stopped when that is true, and states plainly that nothing is deleted. Cancel is the default
button: the pointer slip that opened the dialog must not also answer it.

There is no undo stack behind it. Unarchiving is one click away in the Archived scope, and a
second repair mechanism for an already reversible gesture would only be a second thing to get
wrong.

### An archived session is out of reach, and says so at the seam

`SessionLauncher.launch` refuses a session whose status is `archived`. Hiding the command would
have been enough for the interface, but #10's Restart and #11's restore walk the whole store; the
refusal is where the rule holds for them too.

## Out of scope

Deleting a session for good, and pruning old archives. Restarting a closed session (#10) and
restoring sessions at launch (#11) — this ticket only guarantees them that an archived session is
never resumed. Editing notes (#16), live Git context (#14), changed files (#13), grouping by
folder (#27). Archiving a multiple selection, dragging to the archive, exporting an archived
session, and persisting terminal scrollback.
