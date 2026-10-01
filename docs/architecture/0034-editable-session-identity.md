# 0034 — Editable session identity

- Status: accepted
- Date: 2026-09-29
- Issue: [#183](https://github.com/hadrienl/vibe-manager/issues/183)

## Context

A session's name and badge (`SessionAppearance`: a symbol, a colour, and the project's icon of #27)
were chosen once, at creation (ADR 0007). #183 lets the user rename a session and change its icon
afterwards, from its row, the Session menu and the inspector, in any state — running, closed or
archived — with ⌘Z.

## Decisions

### The identity is only what the session is shown as

`EditSessionIdentity` writes `name` or `appearance` through `SessionRepository.mutate`, and nothing
else: not the branch nor the worktree, not the agent and its resume identifier, not the lifecycle,
not `updatedAt` — a rename is not an activity, and the Last Activity sort must not move because of
it — and not the rank. It never reaches `SessionLauncher`: no process is stopped, started or sent a
byte, and a running agent goes on as if nothing happened. The name enters no launch plan and no
environment; it is only read again by the summary of a later restart (`SessionContextBrief`).

Nothing new is stored: `sessions.json` already holds both fields.

### One rule for a name, checked where names come in

`SessionName` is the rule of a creation and of a rename: one line — a pasted line break or tab
becomes a space — trimmed, not empty, 120 characters at most, an emoji counting as one. A name a
template or a folder proposes is cut to the limit on a whole word rather than refused: a creation
never refuses a name the user did not type.

The limit is not checked by `WorkSession.validate()`. A session stored with a longer name, by an
earlier version or by hand, still loads and still takes its other changes.

### One rule for the default icon

`SessionAppearanceCatalog.defaultAppearance(forName:projectIcon:)` is what a creation gives when the
user picks nothing, and what Revert to Default Icon gives: the project's icon when the folder has
one, over the symbol and colour the name gives — among the lists the Settings offer now (#199,
ADR 0035). The folder is looked at again when the popover opens,
with the same `ProjectIconFinding` as the New Session draft. As at creation, an icon is copied into
the data folder before the session names it; if it cannot be, nothing changes and the user is told
— they chose that icon.

### Nothing is written before it is kept

The name field and the popover work on a draft. Escape drops it and leaves nothing in the store nor
in the undo history. While the popover is open, `AppModel.displayedAppearance(of:)` previews the
badge on the row, the group's header and the inspector's header. Closing the popover — Done, Return,
a click elsewhere — writes it as one change.

A name that cannot be kept is refused in the field, with the reason under it, and the field stays
open. Leaving the field then drops it, rather than holding the keyboard the user took elsewhere.

### Where the name is edited

In place, on the session's row: a double-click on the row — through the list's
`contextMenu(forSelectionType:primaryAction:)`, never a gesture on the row, which kept the clicks
the list needs (#96) — or its context menu. The primary action also receives Return, which hands the
keyboard to the session; only a double-click renames. A double-click on the row's badge opens the
Change Icon popover instead: the rows report where their badges end with a preference, and the click
is compared with it, the list saying only which row was clicked.

The inspector gains a fixed header above its sections: the badge, which opens the popover, and the
name, renamed by a double-click or its pencil. Rename… (⌃⌘E) and Change Icon… (⌃⌘I) in the Session
menu edit the row when the sidebar shows it, the inspector's header otherwise; a folded group is not
unfolded for it. An archived session is renamed in the inspector, from the archive list's menu.

### ⌘Z: a history of its own

The window's undo manager is shared by every text field, and the composer empties it each time it
sends a prompt (a replaced text would otherwise leave undo records that crash). A rename registered
there would be lost at the next prompt, and would answer a ⌘Z typed in a terminal.

`SessionSidebarHistory` keeps the last 50 changes for the run — renames and icons, and archives
since #242, a batch archive as one entry. Undoing applies the reverse only if the session still has
the identity the change gave it (still archived, for an archive); otherwise the change is dropped
and the Mac beeps. The sidebar's list and the inspector take `undo:` and `redo:` with `onCommand`: the hosting
view answers them only while the keyboard is inside the view that declares them, so a ⌘Z in the
terminal, the composer or the notes goes on to what holds it. With nothing to undo, the action is
`nil` and ⌘Z reaches the window as before. A text being edited inside those views — the name field,
the notes — is under the view that declares the command, which takes ⌘Z before the window would hand
it down to the text: the action gives it back to the text's own undo manager. The Edit menu says Undo, without the name of the action.

### Everything that shows the session follows

The sidebar, the group's header, the window's title (#159), ⌘1…⌘9, Open Quickly (#37) and the
palette of requests (#40) read the sessions and follow. The change is shown at once, before the
store is written, then read back. A notification already posted for a request of the session is
posted again under the same identifier with the new name, without a sound — only after a rename,
only while requests are notified, and only if it is still shown: one the user dismissed stays gone. The badges of Open
Quickly, the palette and the archive now draw the project's icon too, rather than its symbol.
