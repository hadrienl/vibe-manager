# 0032 — A library of avatars

- Status: accepted
- Date: 2026-09-28
- Issue: [#154](https://github.com/hadrienl/vibe-manager/issues/154)
- Amends: [0029](0029-floating-panel-and-avatars.md), whose single avatar becomes the avatar in use
  of a library

## Context

ADR 0029 kept one avatar, in `Avatar/`: generating or importing another replaced it the moment it
was used, and going back to the default one deleted it. #154 gathers the settings of the requests
into one tab — Settings › Requests, with the pages Alerts and Avatars — and lists every avatar
produced, so that one can go back to another without drawing it again. A list of avatars needs a
library on disk, and the avatar of the versions before it must be found there.

Four principles of #154 decide most of what follows:

1. One feature, one tab: the requests, the palette, the floating panel and the avatars.
2. Nothing is cut, nothing jumps: both pages have the same size, 900 × 700 points.
3. **What was produced is never lost without asking.** No implicit overwrite; a draft outlives the
   Settings window and the application; the old avatar is taken in even unreadable; deleting is
   always explicit and confirmed.
4. The library is the only truth on disk: the avatar in use, the order and the drafts live there,
   not in `UserDefaults`, so that an avatar deleted cannot stay in use.

## Decisions

### A port, and its rules apart

`AvatarLibrary` (in `VibeApplication`) replaces `AvatarStore`: `entries()`, `canCreate()`,
`load(_:)`, `thumbnail(_:)`, `saveDraft(_:basedOn:)`, `updateDraft(_:with:)`,
`draftToComplete(_:)`, `keep(_:)`, `rename(_:to:)`, `duplicate(_:)`, `remove(_:)`, `inUse()`,
`setInUse(_:)`. Every change is whole or not at all. An avatar is `AvatarID.default` or
`.stored(UUID)`; an entry carries its state (`kept`, or `draft(basedOn:)`), its manifest, when it
entered the library, its size and its problem, if any.

The rules are pure, in `AvatarLibraryRules` and `AvatarLibraryIndex`: the order, the limit, what
deleting the avatar in use does, the name of a copy, what keeping a draft based on another avatar
changes. `InMemoryAvatarLibrary` and `FileAvatarLibrary` pass the same contract
(`VibeAvatarLibraryTesting`). `AvatarWorkshop` does not change: it still makes candidates, and
knows nothing of where they are kept.

### On disk

```
Avatars/                 0700, beside the session store
  library.json           the index
  library.lock           held while the library is changed
  <uuid>/manifest.json   the manifest of an archive (name, source, agent, description, date)
  <uuid>/neutral.png …   the ten sprites, 512 × 512, 0600
  <uuid>/sheet.png       the sheet they were cut from, the reference to draw one again
```

```json
{ "format": 1, "inUse": "<id>|default",
  "entries": [ { "id": "<id>", "state": "kept|draft", "basedOn": "<id>",
                 "addedAt": "2026-09-28T10:00:00.000Z" } ],
  "legacy": { "inode": 1234, "modifiedNanoseconds": 1790000000000000000 } }
```

- **Each avatar is written as `Avatar/` was**: in a hidden staging folder, then moved in with one
  rename. `library.json` is rewritten after it, atomically.
- **The index is only an index.** Missing, it is rebuilt from the folders: a folder without an
  entry is added, kept, at the date of its manifest or of the folder; an entry without a folder is
  dropped; the avatar in use goes back to the default one. Unreadable, or of a later `format`, it
  is set aside as `library.unreadable-<seconds>.json` — never written over — then rebuilt. An index
  read is made consistent: each avatar once, `basedOn` only on a kept avatar, the avatar in use a
  kept one.
- **The order is the order of arrival**, `addedAt`, not the manifest's `createdAt`: an archive
  imported arrives just above the card that makes a new avatar, whatever its date.
- **An avatar that cannot be read, or lacks expressions**, stays listed with why (`problem`):
  “Unreadable”, or “Incomplete” with a draft to complete it (`draftToComplete`). It is never
  deleted but by the user; until it is complete, it is neither used nor duplicated.
- **The default avatar** is the virtual entry `default`, read from the application's resources and
  never written. It is used, exported and duplicated — its copy is “Default Avatar (copy)” — never
  renamed nor deleted.

### Drafts

What a generation, an import or a redrawing brings back is written at once as a **draft**, even
beyond the limit, and even with no window open: a generation costs one to two minutes and quota,
and losing it by quitting would be the worst case. A draft is kept — and put in use when the box
“Use it in the floating panel”, checked by default, says so — or discarded.

- **Drawing again one expression of a kept avatar does not change it.** It makes a draft **based
  on** it (`basedOn`), or changes the one already made. Kept, that draft replaces the original's
  images, sheet and description; the original keeps its identifier, its name — even renamed
  meanwhile —, its place and its use. A draft based on another is not counted in the limit, since
  it will replace it. Its original deleted, it becomes an ordinary draft.
- An expression of a draft drawn again changes the draft where it is (`updateDraft`).
- A generation that failed stays listed for the run only, to try again or remove. One whose result
  could not be written keeps it in memory, to be written again without drawing it again; removing
  it asks first.

### The limit

**20 avatars at most**, drafts included — 3 to 6 MB each, 120 MB at most. The port says
`canCreate()`; the page greys out the card “Create a New Avatar” with the reason, and refuses an
import or a drop with the same sentence. What is refused is a new creation — generating,
importing, duplicating —, never the writing of what was already made.

### The avatar of earlier versions

`Avatar/` is **taken in, kept and in use, even unreadable**: at the first launch, and again
whenever an earlier version wrote one since — going back to an earlier version, then forward, the
avatar made meanwhile is the user's latest choice. The order is always the same:

1. `Avatar/` is copied (an APFS clone) into a staging folder, its files made `0600`;
2. the copy is renamed into `Avatars/<id>/`;
3. the index is written with this avatar in use, and a mark of the folder taken (`legacy`: its
   inode and date);
4. **only then** is `Avatar/` renamed out of the way in one step, and cleared with the leftovers.

An interruption, or an index that cannot be written (a full disk), starts over from the
beginning: at worst a second copy, never less; the avatar in use is never given back to the
default one. An `Avatar/` that cannot be moved stays, and its mark keeps it from being taken twice
while it is unchanged.

### Two instances, and changes on disk

Every change takes `library.lock` (`flock`, released with the descriptor even when the process
ends, waited for 5 seconds at most) and reads the index again under it before writing it. The
leftovers of an interrupted change — staging folders, the previous images of an avatar being
replaced, the old `Avatar/` — are cleared under the same lock, never while another change is under
way.

A reading needs no lock: it goes back to `library.json` when its inode or its date changed — the
other instance rewrote it. The model reads the library again each time the tab appears, and after
each change it makes.

### What was produced is never lost

- A new avatar whose index could not be written keeps its folder: the next reading takes it back,
  kept, like any folder unknown to the index. The change still says it failed.
- A deletion, or a change of the avatar in use, that fails is undone.
- Should the images of an original fail to come back after a failed replacement, its copy is kept
  as `recovered-<id>-…`, which nothing clears.

### Confirmations

Deleting an avatar, and discarding a draft, ask first — deleting the one in use says that the
floating panel goes back to the default avatar. So do the gestures that lose a drawing:
removing a generation whose result was not written, and drawing a whole draft again. Editing the
description of a failed generation does not replace, unasked, one being written in the card.

### Accessibility

Each row of the list is one VoiceOver element: its name, where it comes from and when, then its
states as its value — in use, to check, a generation under way and for how long in whole minutes
(read again each minute, not each second), failed and since when, unreadable, incomplete. Its
actions are those of its menu that can be done now, and Cancel,
Try Again, Save Again, Remove for a generation. The card is a button whose value says Folded or
Unfolded and, greyed out, why. An expression the avatar lacks is said missing. The model announces
the start and the end of a generation or an import, a failure, an avatar kept, put in use, deleted
or discarded — each once: a draft kept but not put in use is one sentence, and an avatar deleted
while it is redrawn is not said cancelled first — through one `announce` that the tests replace. The words are tested without the
views: SwiftUI builds a hosted view's accessibility tree only for an assistive application.

## Consequences

- **An earlier version** reads only `Avatar/`, which is gone: it shows the default avatar, and
  leaves `Avatars/` alone. Nothing is written twice for it; its own `Avatar/`, if it writes one, is
  taken in on the way back.
- The floating panel reads `AvatarLibraryModel.inUseImages`: changing the avatar in use changes the
  panel at once.
- `library.json` is not a user file: hand edits are taken as they are and made consistent, and a
  damaged one is set aside, never lost.
- Checked by hand only: the migration of a real `Avatar/`, two instances changing the library at
  once, a generation that goes on once Settings are closed and a draft found again after quitting,
  VoiceOver and the keyboard alone on the page, a real drop of a `.zip`.
