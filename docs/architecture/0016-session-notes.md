# 0016 — Notes kept on a session

- Status: accepted
- Date: 2026-09-24
- Issue: [#16](https://github.com/hadrienl/vibe-manager/issues/16)

## Context

Notes have been part of the session since #2: `WorkSession.notes`, persisted in `sessions.json`,
searched by the sidebar (#9), and handed to an agent in the restart and handover summaries (#10,
#15). No interface ever wrote one. The inspector drew them read-only, under the Git pane #14 set
aside for them.

An editor saves while the user types. Saved inside `sessions.json`, every pause in the typing would
rewrite, synchronize and back up the whole document; its backup would only ever hold the state of
a second earlier instead of the one before the last close or archive; and every close, archive or
switch would decode every session's notes and wait behind the typing in the repository's queue.

## Decisions

### A file per session, apart from the sessions

`Application Support/com.hadrienl.VibeManager/Notes/<session-uuid>.txt` — or `Notes/` in
`VIBE_DATA_DIRECTORY` for an isolated copy — behind the `SessionNotesStore` port, implemented by
the `FileSessionNotesStore` actor.

| Rule | Why |
|---|---|
| UTF-8, the text exactly as typed, no markup | A file anyone can read with `cat` and recover by hand. |
| Written like the session store: temporary file in the same folder, `fsync`, moved over; `0600`, folder `0700` | A crash leaves the old version or the new one, never half. |
| Empty notes are no file | One way to say "no notes". |
| 64 KiB per session (`SessionNotesLimits`), warned about from 56 KiB | About thirty pages. Every session's notes are held in memory for the search; this bounds it. |
| Over the limit, a change is refused whole and said; never truncated | The cut end of a paste is text lost without anyone seeing where. |
| A file already over the limit — written by hand, or by a later version — only shrinks | It must stay editable down to size rather than become frozen. |
| A file that cannot be read is never written over nor removed; the editor says so, with Reveal in Finder, and Copy Notes when it still holds text typed before | Its bytes are the only copy. |
| A file no session names is left alone | A store restored from its backup can bring the session back. |
| Editing notes does not change the session's `updatedAt` | The "last activity" order must not move the session under the pointer while typing; activity is the agent's. |

### The old field is imported once, without a schema change

`WorkSession.notes` becomes `legacyNotes`, which nothing writes any more. At launch,
`ImportLegacyNotes` — registered before any editor can open, which waits for it — writes each non-empty value to its file — unless the session already has notes
— and only then clears the field with `mutate`. Interrupted between the two, the next launch finds
the file and only clears the field: at no moment does the text exist nowhere. A workspace without
a notes store (`NoSessionNotes`) refuses the import, so the field stays where it is. The v4 DTO keeps
its `notes` key; nothing else in the schema moves.

### Saved as it is typed

`NotesDocument`, one per session for the length of the run, holds the `NSTextStorage` every editor
shows, the `UndoManager` that goes with it, and the writes.

| When | Why |
|---|---|
| 1 s after the last keystroke, and at most 5 s after the first unsaved change | Soon enough that a crash costs a sentence; late enough not to write per key. |
| At once when the session is left, the editor loses the focus, the application is deactivated, and at quit | The moments the user considers the note done. |
| Each write carries a revision; writes never overlap, and "Saved" is only said when the revision on disk is the last one typed | Two writes in flight cannot finish in the wrong order and call an older text saved. |
| A failed write keeps the text in memory and is retried after 1, 2, 4… up to 30 s, and at every keystroke | A full disk must not cost what is being typed. |
| At quit, before the shutdown deadline starts, every pending write is flushed for at most 2 s; any still not on disk asks: Cancel (the default), Copy Notes and Quit, Quit Anyway | The only notes ever lost are those the user chose to lose, and a write stuck on a stalled volume cannot keep the application from quitting. |

The header says **Saved**, **Edited**, **Saving…** (only past 300 ms, so a pause in the typing does
not flash it), **Not saved** — a button whose popover gives the reason, the retry, Copy Notes and
Retry Now — or **Unreadable**, in words and with a symbol, never by a colour alone. VoiceOver announces a failed
write and the first save after it, not every save.

### A plain text view that behaves like the Mac's

An `NSTextView` in TextKit 1 rather than `TextEditor`, which on macOS 14 has neither clickable links,
nor an undo manager per document, nor a find bar.

- Plain text only: a paste keeps the text, drops the styles; Windows line endings become `\n`.
- No automatic quotes, dashes, replacements or corrections — `--force` must not become `—force` —
  spelling underlined only.
- ⌘Z and ⇧⌘Z are the session's own: the text view asks the document for its undo manager, so they
  can never undo a keystroke typed in another session. The history lasts the run.
- One text storage per session, shared by every view on it: TextKit 1's ordinary case, so the same
  session in two windows is one text and one file. Changing session swaps the storage and puts back
  the selection the session had.
- Links are found by `NSDataDetector` in the paragraphs a change touches, kept as attributes of the
  storage, never written to the file. Only `http`, `https` and `mailto` open, through the
  `FileOpening` port of #14; `file:` is revealed; other schemes are not links. A click in a note
  must not launch an application through a custom scheme.
- **Edit Notes** (⌥⌘N) shows the inspector if it was hidden and gives the editor the keyboard;
  Escape gives it back to the session's terminal, through a focus request on its pane.

The Session pane puts the notes first, taking the room there is, and folds the agent and the
initial prompt below them into a section of at most 45 % of the pane, its state kept in
`WorkspaceLayout.isSessionDetailsExpanded`.

### Search and summaries

`NotesModel` reads every session's notes off the main thread at launch into a search index, then
keeps it up with the typing. `SessionFilter.apply(to:notes:)` searches it — and is only handed it
when there is something to search for, so typing in the notes does not redraw the sidebar.

`SessionContextBriefBuilder(for:notes:)` and `SessionBriefInput.notes` take the notes as a
parameter: the builders stay pure. A restart flushes the session's notes and reads them from the
store; a switch reads them from the editor. When the notes do not fit the 16 KiB of a summary, the
section is still dropped whole (#10), and the sheet now says so, with their size, so the user can
paste what matters.

## Consequences

- Typing never touches `sessions.json`, its backup, or the repository's queue.
- The notes are outside the session store's backup and recovery. They are one small file each,
  written atomically; a damaged session store no longer takes them with it.
- Nothing here uses the network: reading, writing, searching and finding links work offline.
- Notes remain user data under ADR 0002's rules: private, never logged.

## Out of scope

Markdown rendering, checklists and rich text; paths, issue numbers and commit hashes as links;
attachments; a version history beyond the run's undo; synchronisation; notes written by the agent;
a preview of the notes in the sidebar; removing the files of sessions that no longer exist.
