# 0027 — Dropping files into a session

- Status: accepted
- Date: 2026-09-26
- Issue: [#42](https://github.com/hadrienl/vibe-manager/issues/42)

## Context

Handing a file to an agent meant typing or copying its path. Terminal.app and iTerm2 type the path
of a file dropped on them; SwiftTerm, which draws the session's terminal (ADR 0004), registers no
dragged type at all, so a drop on it did nothing. The conversation view of #38 could already join
files to a message, and took a drop of files — but in the order they happened to load, and only
while its composer was ready.

## Decisions

### A file becomes its path, typed into the session

No provider exposes an attachment of its own: Claude Code and Codex are command-line programs
driven through a pseudo-terminal, and the terminal stays the one road to them (ADR 0025). A file is
therefore its absolute path, escaped the way Terminal.app escapes a dropped file, typed into the
session's input. `PathInsertion` is the one encoder, for the composer, the terminal and the rows of
the sidebar. Accents and emoji are written as they are and the name is never normalized, so the path
stays the one on disk; a path holding a control character is not written at all and is reported.

A drop never sends anything. In the terminal the paths are followed by a space, as Terminal.app
does, never by Return, and they are wrapped in a bracketed paste when the program asked for one:
that is how Claude Code recognizes an image path and joins the image. In a conversation files become
chips of the composer and text joins the draft; the user sends.

### One zone per session, one reader per drop

The drop is taken by SwiftUI on the column that holds the session's terminal and conversation. The
terminal lets the drag through because SwiftTerm registers nothing, and the conversation is dropped
on over all of its surface. `DropReader` reads each element on its own, in this order: a file, an
image, a web address, text, and last a file the source promises (Mail, Photos). An image dragged out
of a page carries both its bytes and its address; the bytes are kept, because an agent reads an image
from a file. The elements load concurrently and are put back in the order of the drop.

Asked for any item, SwiftUI does not hand a file of the disk over as a file URL but under the file's
own type — plain text, a folder, a PNG — to be opened in place. Read as that type, a text file gave
its content and a folder or an image a copy (#131). A file is therefore also what a provider opens in
place, and only when the URL it gives is the original: a copy made for the reading is not one.

The composer's text field is the exception the surface had (#146). SwiftUI draws it with an
`NSTextView`, which AppKit gives a drag before the zone, being the frontmost view registered for it:
it typed a file's path where it was let go. The field keeps the drags of text — a selection of a
page, a text from another application, a web address — and inserts them where they are let go, as a
text field does. A drag that carries a file, a folder, an image, with or without a file, or a
promised file is handed, from its entry to its end, to the view that would take it without the
field: the zone, which makes chips of it as anywhere else, with the same veil and the same refusals.
`TextEditor` exposes neither its text view nor what it accepts, so the text view it made is given,
at run time, a subclass of its own class that overrides the methods of `NSDraggingDestination` and
nothing else, as key-value observing does; pasting is left alone. A text view SwiftUI could not
give it to keeps AppKit's behaviour.

Where the drop goes is decided by `SessionDropRoute`, a pure function of the session's presentation,
its process and its composer:

- a terminal takes it while its process runs;
- a conversation takes it while its composer is ready, starting or waiting for an answer in the
  terminal — joining sends nothing, the file waits in the composer;
- a conversation that cannot be written to from here falls back to the terminal, and says so;
- a stopped or archived session refuses it while the drag still hovers: a red veil, and no "+" on
  the pointer. Nothing is kept for later.

The drawer of side terminals (#43, ADR 0030) lies under that column, outside its zone, and has its
own (#139): a drop is typed into a side terminal, never into the agent's, by the same rules — the
same reader, the same `Drops/<session>/`, the same encoder, a bracketed paste when its program asked
for one. The target is the terminal under the pointer, not the one that has the keyboard: over the
terminal area, the tab in front; over a tab of the bar, that tab, which comes in front, as a row of
the sidebar selects its session. A tab of the bar also takes the tabs dragged along it: its drag
carries a prefixed text (`DrawerTabDrag`), which moves the tab and which no drop ever types; anything
else — a file, an image, a promised file, a text — is dropped into that tab's terminal. While the
drag hovers, a tab is told apart by the drag's pasteboard, since the drop's items cannot be read
before it is let go; the drop itself goes by what it carries. Every drop on a tab proposes a copy,
the tabs' included: a text view lets its text be copied, never moved. The rest of the bar, the + and
the button that hides the drawer, takes nothing. A side terminal takes a drop while its shell runs,
whatever the agent does; one whose shell ended refuses it — a file or a text alike — with the red
veil, and its tab does not come in front. The notice of a drop stays at the top of the
session's column.

A row of the sidebar takes the same drop: the session is selected, then receives it. A drag that
rests on a row for 0.8 s selects its session, as the Finder opens a folder, so that the drop can be
let go exactly where the user wants in its view.

### What has no file is written in `Drops/<session>/`

An image with no file of its own, a floating screenshot (a file in a temporary folder the system
empties behind the drag) and a promised file are written in `Drops/<session>/`, next to
`sessions.json`, owner only. Not `$TMPDIR`: macOS empties it after three days, while a session can
last longer, run without the application (ADR 0017) and be resumed; and each copy of the application
pointed at its own data directory keeps its own. The data directory is not a place TCC guards, so
the agent reads these files without asking. A file that exists is never copied: the agent reads and
edits the original.

The folder goes when the session is archived. The application has no deletion of a session yet;
the leftovers of a crash, and of sessions archived before, are swept at launch — never against an
empty list, which may be a store that could not be read.

### No security-scoped bookmark

The ticket asked to keep the access the drop grants with a security-scoped bookmark. It would give
nothing: the application is not sandboxed (ADR 0001), and the process that reads the file is the
agent, responsible to the terminal host (ADR 0010), to which a bookmark opened by the application
does not travel. Access is Full Disk Access, as #31 decided. When it is known to be missing and a
dropped file lies in a protected folder, the drop still happens and a bar says the agent may have
to ask for access, with a way to the Privacy settings. Copying the file instead would have made it
readable, but the agent would then edit a copy.

### The keyboard

Session › Attach Files… (⌘O) opens a file panel — files and folders — and delivers the choice as a
drop would. Every drop is announced to VoiceOver.

## Consequences

- A dropped path is a user's keystrokes: it travels through the pane's input, like a paste, and is
  never read as the answer to an agent's permission (#45).
- Text dropped on the conversation outside the composer's field joins the end of the draft, not
  the position of its cursor, which SwiftUI's text editor does not expose; dropped on the field, it
  is inserted where it is let go.
- A drop on a session whose agent has not asked for bracketed pastes — a bare shell — types the paths
  as characters, which is what Terminal.app does too.
