# 0025 — Recent working folders

- Status: accepted
- Date: 2026-09-26
- Issue: [#39](https://github.com/hadrienl/vibe-manager/issues/39)

## Context

Every session starts with a working folder, and most of them start in a folder a session was
already created in. The New Session sheet made the user find it again each time, through the open
panel or by typing its path.

It proposed no folder on purpose. The home directory used to be the default, and it is the one
place that contains Desktop, Documents and Downloads without being guarded itself: accepting it let
an agent walk into them with nothing said. ADR 0010 then made sure that opening the sheet raises no
consent alert: the disk is read where the user designates a folder, never before.

## Decisions

### Only folders the user already chose

The sheet proposes the folders sessions were created in, the most recent first, and nothing else:
nothing is guessed or searched. A folder enters the history when a session is created in it —
launched or left in To Do, whether it came from the open panel, a card, a typed path or a template.
Cancelling the sheet records nothing.

The history holds ten folders. Choosing one again moves it to the top. Its identity is its
canonical path (`CanonicalPath.of`), resolved when it is recorded: creation has just opened the
folder, so reading it again raises no alert that has not been answered already. Two spellings of
one folder, `/var/x` and `/private/var/x`, are one entry, under the spelling used last.

### A preference of this Mac, not a fact about the work

`RecentFolders` is kept in the user defaults (`newSession.recentFolders.v1`), beside the layout
(ADR 0008), by `UserDefaultsRecentFolderStore`. It stays out of `sessions.json`: losing it costs one
trip through the open panel, and the session schema does not change. It is read entry by entry, so
an unreadable entry costs that entry only.

An installation that never wrote a history starts from its sessions — when they could be read:
seeding from a store in failure would write an empty history that no later launch replaces. It
takes their folders, the most
recently created first, compared by spelling since nothing may be read at launch. A history written
empty is not seeded again, so folders removed one by one do not come back.

### Opening the sheet raises no alert

When the sheet opens, each recent folder is looked at through `WorkingDirectoryProbe`, side by side,
within 300 ms. A folder macOS guards (`ProtectedFileLocation`) is only looked at when Full Disk
Access is known to be granted: a `stat` inside `~/Documents` is enough to raise the alert ADR 0010
took out of this sheet. Those, and the folders a slow volume has not answered for in time, are
*unverified*: offered as they are, and checked at creation like any folder. A folder counts as
guarded when its path or its canonical key is: a link to `~/Documents` leads into `~/Documents`.

`FileManagerWorkingDirectoryProbe` answers from a Dispatch queue, not from the cooperative pool:
`stat` on a network volume that went away blocks its thread for as long as it takes, and ten such
threads taken from the pool would starve every task and actor of the application — the budget
meant to give up on them included.

### The last folder is preselected — or the next one, said aloud

An empty field receives the most recent folder that has not gone. When the last one has gone, the
next one is proposed and the sheet says so under the field ("“api” was not found — the next recent
folder is proposed."): an agent must not start in another repository without the user seeing it.
When all have gone, nothing is preselected and the sheet behaves as before.

A preselected folder is a default, like a template's folder: a template picked afterwards replaces
it, and a template without a folder gives it back. A template opened with its own folder wins over
it. A folder the user picks — a card, the open panel — is theirs, and no template replaces it.

A folder that has gone keeps its card, dimmed and marked "Folder not found": a volume unplugged for
now comes back. Remove from Recents, in the card's menu and as an accessibility action, is how it
goes for good. There is no setting.

### Cards like the agents

The folders are shown in one column, as the agents are, with the same component: `ChoiceCard`,
taken out of `AgentChoiceRow`. Three cards, then Show N More, which unfolds the column in place up
to ten and becomes Show Fewer. A card shows the folder's name — told apart from a namesake by the
nearest enclosing folder that differs, `api — client-a` — and where it is; its help tag gives the
full path. A card is selected when the field names its folder, compared by spelling, so a typed path
lights its card too. Choosing a card checks the folder like the open panel's answer, since it is the
same gesture.

## Consequences

- `AppModel` no longer takes a default working folder: the history replaces it.
- The project icon of #27 has a place on the card's symbol when it lands.
