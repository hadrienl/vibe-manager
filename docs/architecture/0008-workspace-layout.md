# 0008 — The three-column workspace

- Status: accepted
- Date: 2026-09-22
- Issue: [#8](https://github.com/hadrienl/vibe-manager/issues/8)

## Context

Creating a session (#7) already produced a sidebar and a terminal, because a session had to be
shown somewhere. This ticket turns that minimum into the workspace itself: sessions on the left,
the selected terminal in the middle, the context of that session on the right — and it makes the
promise the whole application rests on explicit.

**Changing session changes what is shown, and nothing else.** No process is started, stopped or
rebuilt, and no scrollback is lost. Everything below follows from that sentence and from its
consequence: the window has to remember where the user was.

## Decisions

### A split view and an inspector, not three columns

The left column is the `sidebar` of a `NavigationSplitView`; the right one is an `.inspector` on
the detail column. A three-column split view means "list, then detail": its middle column
narrows the selection. Here the right column describes the session that is already selected,
which is what an inspector is. Taking the system component also takes its separator dragging,
its fold, its ⌃⌘S, and its VoiceOver behaviour — none of which is worth reimplementing over a
stack of `HSplitView`.

### The panes stay mounted; only which one is opaque changes

Every session's `TerminalPaneView` is rendered in a `ZStack`, and the unselected ones are drawn
with `opacity(0)`, without hit testing, and hidden from accessibility so VoiceOver only ever
reaches one terminal. Removing a pane from the hierarchy would call `dismantleNSView` on its
SwiftTerm view: the history would replay on return, but the scroll position would be gone and
the first frame would be an empty terminal. This decision predates the ticket — it was found
the hard way while building #7 — and is recorded here because it is what makes the promise true.

The panes themselves belong to `SessionLauncher`, not to a view: a view that owned a pane would
restart an agent every time SwiftUI rebuilt it.

### The layout is a preference, and it lives in the user defaults

`WorkspaceLayout` — selection, column visibility, column widths — is written to `UserDefaults`
behind a `WorkspaceLayoutStore` port, never to `sessions.json`. A window width is a fact about
this Mac, not about the work. Keeping it out of the session store means no interface change can
force a schema migration, and a layout that cannot be read costs the user one drag rather than
their sessions.

`@SceneStorage` was the other candidate. It restores per scene, at a moment the application does
not control, and it cannot be tested without a window; the ticket asks for a selection restored
at launch, which is a question the model must be able to answer on its own.

### Intent and result are two different things

`WorkspaceLayout` records what the user asked for. `WorkspaceLayoutPolicy.resolve` answers what
fits, given the window's width: the inspector folds below 1 040 points, the sidebar below 820.
Folding is never written back as a decision, so widening the window brings back exactly the
columns the user had open, and a column they closed themselves stays closed at any width.

The policy is a pure function over a value, so every threshold is tested without a window, and
the views are left with nothing to decide.

### Widths are measured, because they are not reported

SwiftUI takes an `ideal` width for a split column and never says what the user dragged it to.
Each column therefore measures itself through a `GeometryReader` and reports back; the
controller bounds the value and saves it. Saves are delayed by half a second, so a drag writes
once instead of at every intermediate width, and the pending write is flushed when the
application terminates — which is precisely when a discarded delay would lose the arrangement.

### The stored status is the weakest of three sources

A sidebar row resolves what it shows from the session's stored status, the state of its pane and
the availability of its agent, in reverse order of authority: a process that failed outranks a
session stored as active, and a missing agent is only the headline when nothing is running. The
stored status says what the user intended; the pane says what happened.

`SessionStatusPresentation` returns a symbol, a sentence and a severity — never a colour alone.
The identity colour the user picked for a session already means identity; it cannot also mean
failure. The severity becomes a tint in the view, and the same value builds the accessibility
label, so VoiceOver announces the state that sighted users read.

### The right column shows what the session carries, and says how old it is

Repositories, the Git snapshot stored with them, the agent and its resolution, the notes, the
initial prompt. Nothing is queried: a live Git status (#14) and editable notes (#16) are their
own tickets, and a column that silently showed a stale branch as if it were current would be
worse than one that dates what it shows.

### Shortcuts live in the menus

⌘1…⌘9 select a session by position, ⌥⌘↓ and ⌥⌘↑ walk the sidebar without wrapping, ⌥⌘I toggles
the context column, and ⌃⌘S — the system's own — folds the sidebar. They are menu commands
rather than view modifiers: a shortcut bound to a view only works while that view has focus, and
the menu is also where a keyboard-only user discovers that the action exists at all.

## Consequences

- The workspace is restored at launch: the same session is selected, the same columns are open
  at the same widths. A stored selection naming a session that no longer exists falls back to
  the first one instead of blocking the launch.
- `VibeDomain` and `VibeApplication` still know nothing of SwiftUI: the layout value, its port
  and its policy are plain `Sendable` types, and the only thing the views add is a colour.
- Terminals keep running for every session, selected or not. Memory grows with the number of
  live sessions, which is the price of the promise; grouping and archiving (#9, #27) are where
  that number gets managed.

## Out of scope

Restarting a closed session (#10), restoring agents at launch (#11), several repositories and
worktrees (#12), changed files (#13), the live Git context (#14), editable notes (#16), and
grouping sessions by folder (#27) — the sidebar is a flat list of sections so that grouping can
be added without rewriting it. Reordering by drag, several windows, and more than one terminal
per session are not planned for the V1.
