# 0029 — Ticket titles in the notes

- Status: accepted
- Date: 2026-09-27
- Issue: [#89](https://github.com/hadrienl/vibe-manager/issues/89)

## Context

Most sessions start from a ticket: « Implémente https://github.com/acme/app/issues/42 ». The notes
of the session (ADR 0016) are where the user keeps what the work is about, and the first thing they
would write there is the ticket's title — which the address alone does not say.

Reading a ticket's title needs the ticket's tool, and every tool has its own API, its own
authentication and its own command-line client. A first design went that way: resolvers with three
methods — an HTTP request to a JSON API, a command such as `gh issue view`, a page loaded out of
sight — and tokens in the keychain. It was set aside before any code: the session already has a web
view (ADR 0023) where the user is signed in to the sites they work with, and a page's title is
something every site gives.

## Decisions

### The title is read in the session's web view

The page of each ticket opens in the session's web view, as the user would open it: the pinned
ticket tab when the ticket is the session's (ADR 0023), a new tab in the background otherwise. No
token, no command-line client and no API is involved, and a tool nobody thought of works the day a
resolver names its addresses. The tabs stay afterwards, like any other tab.

A page's title is read — `og:title`, then `twitter:title`, then `<title>` — only when both hold:

- the page answered with a 2xx status (`BrowserTabModel.mainFrameStatus`, taken from the main
  frame's response);
- the address the page ended on is recognised again, by the same resolver, as the same ticket.

A sign-in page, a 401 or 403, or a redirection to another ticket is therefore never read as the
ticket. The reading waits there instead, without a time limit, and the notes say « Sign in to … in
the web view », with Show Tab. Once the user signs in and the site sends them back, the title is
read. A 404 or 410 says the ticket is missing, or not visible to the account signed in.

A single-page application writes its title after loading: a title is taken once it has not changed
for 0.8 s, and a title that is empty, or only the resolver's name once cleaned (« Linear »), is not
one. After 10 s on the ticket's page without a title, the reading gives up and says so.

### A resolver is a configuration

`TicketResolver` is a pattern with named captures, matched from the start of the address and ending
where the address does or before `/`, `?`, `#`; a short identifier built from the captures
(`{owner}/{repo}#{number}`, `{key}`); and regular expressions removed from the title, in order. It
holds no code and runs nothing. GitHub, GitLab (tickets and merge requests), Jira Cloud and Linear
are shipped; a preset the user left alone follows the revisions later versions ship, one they
changed or deleted stays as they left it (`TicketResolverPresets.merge`, with the presets known when
the file was written). An address no enabled resolver recognises opens no tab and loads nothing.

Resolvers are kept in `ticket-resolvers.json` beside the sessions, written like the other stores;
a file that cannot be read is never written over. They are exported and imported as a JSON file
described in [`docs/ticket-resolvers.md`](../ticket-resolvers.md).

### A creation gesture, never in the way of the launch

`CreateSession` recognises the tickets named by the session's ticket field, its name and its prompt
— a template's values are in the prompt already — in that order, each once, five at most. It reads
nothing from the network. When nothing else named a ticket, the first becomes the session's ticket
with the new source `detected`, above the branch's (ADR 0023). A build that does not know the source
reads it as a manual one.

`AppModel.complete` hands the tickets to `TicketTitlesModel` and launches the agent without waiting.
Restart and restoration never go through `complete`: nothing is read again then. The pages of a
session are read one at a time, so five tickets never load five pages at once; one that waits for a
sign-in lets the next one start. A page read for a session the user is not looking at is let go at
once (`BrowserTabModel.discard`), and loads again when its tab is shown.

### The line is an edit of the notes

Each line — `[{id}] {title} — {url}` by default — goes to the top of the notes as soon as its
title is read, through the session's `NotesDocument`, like a keystroke: saved the same way, within
the same limit, never over notes that could not be read. The lines keep the order the tickets were
named in whatever order their pages answered, as long as the user has not changed them; otherwise a
new line goes first. Each is an undo action of its own, « Insert Ticket Title ». A ticket whose
address is already in the notes is not added again.

### Settings

A Tickets tab: the switch (on by default), the line format, the resolvers with their own switches,
an editor with its validation, Restore the Shipped Version, import and export, and a test of an
address that loads it apart from any session and says what would be written — or that nothing would
be loaded. Off, nothing is recognised, no tab is opened and nothing is loaded.

## Consequences

- Reading a ticket is a real visit: a site may mark a notification as read.
- A title follows what the account signed in may see: a private ticket needs the user signed in.
- No title is read for a tool whose pages give none that names the ticket; its resolver's cleanup
  can often fix what they give.
