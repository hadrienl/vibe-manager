# 0025 — Open Quickly

- Status: accepted
- Date: 2026-09-26
- Issue: [#37](https://github.com/hadrienl/vibe-manager/issues/37)

## Context

A session is usually remembered by what was at hand when it was started: a ticket number, the URL
of a merge request, a branch. The sidebar lists sessions by column and by title, and its search
reads titles, prompts, notes and folders — not the tickets, requests, branches and worktrees the
journal (ADR 0023, #36) records for each session.

## Decisions

### A resource is compared by its key, never by its text

What is typed is read first as a URL, a number or a path, and brought to the canonical form of the
journal's resources by the same functions: `ResourceRecognizer.resource(for:)` for a ticket or
request URL, `normalizedBranch` for a branch, `CanonicalPath` for a folder. A URL pasted with a
tab (`/files`, `/diffs`), an anchor, a query, `www.` or a trailing slash is the same key, and there
is no second normalization that could drift from the first. Free text is only what is left.

`QuickOpenQuery` reads:

- a ticket or request URL of GitHub or GitLab (any host of that shape) — its resource key;
- a forge URL of a branch (`/tree/…`, `/-/tree/…`, `/compare/…...…`) — the branch;
- another forge URL — its project, as text;
- `36`, `#36`, `!12`, `owner/repo#36`, `group/sub/project!12` — a number, its repository compared
  by its end. On GitLab `#` is a ticket and `!` a merge request; GitHub numbers both together. A
  bare number is also a fragment of text;
- `/…` and `~/…` — a folder;
- anything else — words, each to be found somewhere in the session, without case or accents.

### An index in memory, rebuilt at every launch

`SessionSearchIndex` (an actor of `VibeApplication`) holds one row per session, archived ones
included: its title, its folders, its resources — the journal's, the branch and worktree the
session recorded itself, and the ticket URLs of its first prompt, for sessions older than the
journal — its summary and its notes, all folded once into bytes. A keystroke only walks arrays; it
never reads the disk.

It is fed by the session store (every list the workspace holds), by the journal monitor's updates,
and by the notes when the palette opens. At launch, after the list is on screen, every journal is
read once in the background, one after the other; the palette searches what is already there and
says it is still reading. A journal the monitor published is never replaced by an older one read
from the disk. Nothing is persisted: an index that cannot go stale is worth reading a few hundred
small files at launch.

### A rank per rule, and the rule said

Each session keeps its best match, and the rule that produced it is what the row says:

1. the very resource — a URL pasted, a number with its repository;
2. a number alone, a branch or a folder named in full;
3. part of a branch, a worktree, a repository or a resource's label;
4. the title;
5. a folder;
6. a line of the summary, shown around what matched;
7. the notes, likewise.

Several words found in different places make the session as good as its weakest word, and it is
described by its strongest. The summary and the notes are only searched for words of two
characters or more.

Results are sorted by rank; at equal rank current sessions come before archived ones, then the
session that created the resource before the one that changed or only viewed it, then the latest
activity. An archived session that matches exactly therefore comes before a current one that only
matches in its summary. With nothing typed, the palette lists the eight sessions last worked in,
the one on screen left out. 50 results at most.

### An overlay of the window, a field of AppKit

The palette is an overlay of `RootView`, not a sheet: the window shows one sheet at a time, a sheet
is modal, and this one closes with a click anywhere else. Its field is an `NSTextField`, so the
arrows, Page Up and Down, ⌃N and ⌃P, Return and Escape arrive as field-editor commands instead of
moving through the text. The keyboard stays in the field; VoiceOver is told the count once the
typing pauses, and the row reached at each move.

### ⌘P, where Print was

File ▸ Open Quickly… replaces Print: there is nothing to print. From Settings or Usage it brings
the workspace forward first; over a sheet it is disabled. ⌘P while open selects the text.

### Going to the session changes nothing else

Return goes through `AppModel.reveal`: an archived session opens from the archive, any other in its
column (ADR 0024). A sidebar search or facet that would hide it is cleared, since the next reload
would otherwise take the selection away. The keyboard then goes to the terminal when the agent
runs, and to the session's row otherwise. No status, no agent, nothing of the session is touched.

## Consequences

- The search depends on what the journal extracted: a ticket only named through an MCP tool's
  arguments, which the journal does not record, is not found by its number.
- Print is gone from the File menu.
