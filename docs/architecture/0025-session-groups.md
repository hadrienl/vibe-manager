# 0025 — Session groups and project icons

- Status: accepted
- Date: 2026-09-25
- Issue: [#27](https://github.com/hadrienl/vibe-manager/issues/27)

## Context

With several projects open at once, the flat sidebar mixes their sessions, and every session of a
project wears a different identity, drawn from its title. This ticket groups the sidebar by working
folder, and gives the sessions of a folder the icon of that project.

## Decisions

### A group is derived, never stored

No session carries a group. `SessionGrouping` cuts the list the filter already produced — searched,
narrowed, scoped and sorted — into one group per folder, and never sorts it again: a group lists its
sessions in the order of the sort, and the groups come in the order of their first session. The
grouped view therefore shows exactly the sessions of the flat one, in the same relative order.

The folder is the session's first repository (#7, #10), where its agent starts. A second repository
(#12) or a worktree the agent made (`git.worktreePath`) never makes a group of its own.

Only what the user wrote or arranged is kept, under the folder's canonical path:

| What | Where | Why |
|---|---|---|
| Flat or grouped | `WorkspaceLayout.sidebarMode` | an arrangement of the view, like the sort |
| Folded groups | `WorkspaceLayout.collapsedFolders` | the same; never pruned, so a group that comes back folds back |
| The archived section, unfolded | `WorkspaceLayout.isArchivedSectionExpanded` | the same |
| Group names | `folders.json`, next to `sessions.json` | text the user wrote, which a corrupted preference must not cost |

Each new layout field is decoded on its own, like the filter: a value a later build wrote costs the
grouping, never the rest of the layout. `folders.json` is written atomically, `0600`; one that cannot
be read is left as it is, and renaming is refused until it can be.

The mode is flat until the user asks: grouping rearranges the sidebar, and it is not the
application's to do that unasked. `SidebarMode` is an enumeration because grouping by priority (#63)
is the next way to list the sessions.

### Folders are compared through their links, off the main thread

A group's key is `CanonicalPath.of` the folder: `/var` and `/private/var`, or a folder opened
through a link, are one group, and two `api` folders in different trees are two. Resolving touches
the disk, so `SessionFolderResolution` does it away from the main thread at each reload; until it
answers, a folder is filed under its path as written, tidied (tilde, `..`, trailing slash), which is
right for almost every folder and never flickers.

Two groups whose folders share a name are told apart by the nearest ancestor that differs —
« api — client-a » — as Xcode and VS Code do. The help tag always gives the whole path.

A folder that was moved or deleted keeps its group under its old path, with `questionmark.folder`
and « Folder not found ». The application does not follow it: its sessions still point at the old
path, and restarting them already says why it cannot (#10).

Sessions without a folder — a store older than #7 — are filed last, under « No Folder ». In the
Closed tab, the archived sessions are listed apart, in an « Archived Sessions » section folded by
default: they no longer count in their groups, and a group whose sessions are all archived is gone.

### The keyboard follows what is drawn

`AppModel.displayedSessions` is the rows on screen, in order, folded groups left out. ⌥⌘↑/↓ and
⌘1…⌘9 walk it, and so do the labels of the ⌘1…⌘9 menu items, which used to read the whole store in
its own order. From a selection a fold hides, ⌥⌘↓ goes on from where that session would be.

Folding the group of the selection keeps it, and its terminal on screen; the header then says it
holds the selection. Selecting a hidden session — quick switch, a new session, a banner — unfolds its
group. A search shows every group unfolded, without touching the folds stored. At launch, folds,
mode and selection come back as they were, a selection in a folded group included.

The View menu has Group Sessions by Folder (⌃⌘G), Collapse Group (⌥⌘←) and Expand Group (⌥⌘→) for
the group of the selection, and Collapse / Expand All Groups. The footer of the sidebar has the same
toggle. A header is an accessibility header, so the rotor walks the groups, with Expand / Collapse
and Rename as named actions.

### The header says the most pressing state, not a colour

`SessionGroupStatus.aggregate` folds the states of the sessions — the same `SessionStatusPresentation`
their rows show — into the most pressing one, drawn with its symbol and, in the help tag and for
VoiceOver, its words. The order puts what only the user can unblock first:

1. a question, then a permission, then an answer not read (#45);
2. a process that ended badly, then an agent that went missing;
3. an agent at work;
4. a process starting or being restored;
5. an agent waiting for an instruction.

Closed, finished and archived sessions have nothing to say. « Agent unavailable » wears the severity
of an attention without being one, so the order reads what the agent is doing rather than the
severity alone. VoiceOver counts the states: « vibe-manager, 3 sessions, 1 needs attention,
1 working, collapsed ».

### A project icon is a default, never a decision

`SessionAppearance` gains `iconID`, the SHA-256 of a PNG kept in `Icons/<sha256>.png`. Symbol and
colour are still always filled, with what the name would have given, and the badge falls back on
them when the file is missing. `SessionIconID` accepts only 64 lowercase hexadecimal digits: it
becomes a file name, and a value read from the store must never point elsewhere.

`sessions.json` moves to v7, for the reason v6 was a version (ADR 0024): a v6 build would read the
document, ignore the icon as an unknown key and erase it at its first write. v7 is v6 with one more
optional field, read by the same structure; v0…v6 are still read, with no icon.

`FileSystemProjectIconFinder` looks in a closed list of places, in three tiers — an application icon
(`AppIcon.appiconset` of an asset catalogue, `.icns`), then a favicon, then `icon` or `logo`, at the
root or in `public/`, `static/`, `assets/`, `app/`, `src/app/` — and keeps the largest image of the
first tier that yields one. It is bounded: three levels deep (an asset catalogue is looked into
wherever the walk reached it), 300 entries listed, files of 2 MiB at most, 300 ms in all. Links are
not followed, and the folders of dependencies and build products are skipped. The image is turned at
once into a PNG of 256 pixels at most (128 if that one exceeds 64 KiB), so what the sheet previews is
what is stored, and anything unreadable means « no icon », never an error.

The folder is read only where the user designated it — the open panel, New Session in This Folder
from a group, and creation — never while a path is typed: reading a folder macOS guards raises the
system's consent alert, and that must follow a gesture.

The draft's `appearance == nil` already meant « not chosen yet ». The default becomes « the project's
icon, else the name ». A symbol or a colour picked by the user is an explicit appearance, without an
icon, and nothing replaces it later, a change of folder included; a « Project icon » swatch goes back
to the icon. `CreateSession` writes the icon before storing the session, and an icon that cannot be
written leaves the session created with the name's identity and a line in the diagnostics log.

Icons are addressed by content: every session of a folder shares one file, importing the same icon
again writes nothing, and moving or deleting the source changes nothing on screen. No icon is ever
removed, for the reason notes are not: a store restored from its backup can bring back a session
that names one.

## Consequences

- Grouping, folding and renaming never touch `sessions.json`, a session or a path.
- Existing sessions keep their identity: the store cannot tell a derived appearance from a chosen
  one, and rewriting a chosen one is what the ticket forbids. A group can therefore show different
  icons until its sessions are replaced.
- A build before this one refuses a v7 store rather than dropping its icons.
- `DataDirectoryPermissions` tightens `Icons/` with the other folders at launch.

## Out of scope

Following a moved folder (bookmarks), reordering groups by hand (#44 will move the mode toggle
where Active and Closed are), and grouping by priority (#63).
