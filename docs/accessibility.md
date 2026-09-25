# Accessibility and the keyboard

What VoiceOver says and what the keyboard reaches, screen by screen. Written for #19, whose
criterion is that VoiceOver and the keyboard allow the main actions: create, select, close,
restart, archive, switch agent, write a note, quit leaving the agents running, export a diagnostic.
Reading a full-screen TUI element by element with VoiceOver is not among them — Terminal.app itself
only does it imperfectly.

Every action below is in a menu, where VoiceOver and a keyboard-only user find it, and none depends
on a view holding the focus. The release checklist walks this document with VoiceOver and Full
Keyboard Access on (see [release checklist](release-checklist.md)).

## Moving around the window

| Shortcut | Command | Menu |
|---|---|---|
| ⌥⌘1 | Focus Sidebar: the session list takes the keyboard | View |
| ⌥⌘2 | Focus Terminal: the selected session's terminal | View |
| ⌥⌘3 | Focus Inspector: the Git list, the inspector shown if it was hidden | View |
| ⌥⌘N | Edit Notes; Escape gives the keyboard back to the terminal | View |
| ⌥⌘↓ / ⌥⌘↑ | Next / Previous Session | View |
| ⌘1…⌘9 | The session at that position in the list | View |
| ⌃⌘→ | Next scope (Current, Closed, Archived, All) | View |
| ⌥⌘I | Show / Hide Context | View |
| ⌃⌥⌘O | Read Last Output: VoiceOver says the last five lines the terminal showed | View |

An agent running in the terminal loses ⌥⌘1, ⌥⌘2 and ⌥⌘3, which full-screen programs rarely use; the
menus already took the others before #19.

## Sessions

| Action | Shortcut | Menu |
|---|---|---|
| New Session | ⌘N | File |
| New Session from Template | ⇧⌘N | File |
| Create & Launch, from anywhere in the sheet | ⌘↩ | — |
| Restart | ⌃⌘R | Session |
| Restart in a new process, from anywhere in its sheet | ⌘↩ | — |
| Switch Agent… | ⌃⌘M | Session |
| Close Session | ⌘W | Session |
| Archive… / Unarchive | ⌃⌘A / ⇧⌃⌘A | Session |
| Close Window | ⇧⌘W | File |
| Usage window | ⌥⌘U | Window |
| Export Diagnostics… | — | Help |

## What VoiceOver reads

| Element | Label | Value | Actions | Identifier |
|---|---|---|---|---|
| Session list | "Sessions" | — | — | `session-list` |
| A session row, one element | name, agent and model, status ("Refactor, codex gpt-5, Running") | "Restoring" while it is | Restart, Switch Agent, Close Session, Archive, Unarchive — each only when it applies | `session-row` |
| Terminal | "Terminal — ‹session› — ‹status›" | the visible screen, as text, read-only | Read Last Output (⌃⌥⌘O) | `terminal` |
| Notes | "Notes for ‹session›" | the text | editable | `notes-editor` |
| Git inspector | the list of repositories and files | — | Open, Reveal in Finder, from the context menu | `inspector-git` |
| New Session: name, prompt, folder, Create | their labels | — | — | `new-session-name`, `new-session-prompt`, `new-session-folder`, `new-session-create` |
| Diagnostics preview | "Diagnostics preview" | the whole text of the export | searchable (⌘F) | `diagnostics-preview` |

### The terminal

SwiftTerm 1.20.0 exposes nothing to accessibility on the Mac. `AccessibleTerminalView` makes the
terminal one read-only text area whose value is the screen as it is now — the visible lines, not
the scrollback — so VoiceOver reads it with its usual text commands. Its label names the session
and what its agent is doing.

Output is **never** announced as it arrives: an agent writing fifty lines a second would make
VoiceOver unusable. Read Last Output says the last five lines that say something, with escape
sequences removed and a line rewritten by carriage returns reduced to what it ended as.

### Banners

A banner appears away from VoiceOver's cursor, so each one is announced as it appears: a
restoration under way, the offer to resume after a crash, the report of a restoration, sessions
taken back from the terminal host, a host that could not be reattached, another copy running the
same sessions, a store that could not be read, an agent that will stop with the application, a
restart that failed. The restoration banner is also marked as updating frequently, and is read once
per session, never once per line.

### Colour

A status is never said by colour alone: each has its own symbol, and its label says it in words.
With Increase Contrast and Reduce Transparency on, the status badges keep their shape, and the
release checklist looks at them in both.

## Checked by

- `SmokeTests` (XCUITest, `Scripts/ui-smoke.sh`): the nominal journey through keyboard shortcuts,
  on the built application.
- `TerminalTextTests`: the terminal's accessibility element, its screen text and its last lines.
- The release checklist: Accessibility Inspector without warnings on the main window, the New
  Session sheet, Settings and the export sheet; a VoiceOver walk through every action above; Full
  Keyboard Access on.
