# 0023 — A web view per session, driven by its agent

- Status: accepted
- Date: 2026-09-25
- Issue: [#69](https://github.com/hadrienl/vibe-manager/issues/69)

## Context

Working with an agent means looking at pages: the ticket the session is about, the preview the
agent is building on `localhost`, documentation. They were in another application, and the agent
could not see them at all — it had to be told what the page said, or be given a screenshot by hand.

#69 puts a tabbed web view beside the terminal of each session, and lets the agent drive it from its
shell: open a tab, reload, read the page, its console, a screenshot, click, type, run JavaScript.

## Decisions

### The web view belongs to the session, like its terminal

Each session has its tabs, the one in front, and whether its view is shown (`SessionBrowserState`),
kept in `Browser/<session-uuid>.json` beside the store — not in `sessions.json`, which a click on a
link would otherwise rewrite. Changing session shows other tabs and reloads none: a
`WKWebView` belongs to its `BrowserTabModel`, never to a view, the way a terminal's pane outlives
the view that draws it (ADR 0008). A page nobody shows waits in an off-screen window, where it keeps
running and can still be read or captured. A tab restored from a previous launch keeps its address
and title and creates no page until it is shown or an agent reaches for it; a page left unseen for
half an hour in a session not on screen is let go the same way.

Whether the view is shown is the session's; how wide it is, is this Mac's (`WorkspaceLayout`). When
the window narrows, the inspector folds first (under ~1 600 points), then the sidebar (~1 180), and
under ~900 points the terminal and the web view take turns in the same place rather than both
shrinking below what either can be used at. The terminal is never narrowed below about eighty
columns, and never taken out of the hierarchy: when the web view takes its place it is drawn over
it, since a terminal resized to nothing would tell its agent so.

### The ticket

A session's ticket is its first, pinned tab. Only what a person decided is stored, in
`sessions.json` (schema 5): typed at creation or later, or brought by a template field named
`ticket`. Otherwise it is deduced each time from the branch the working folder is on and its
`origin` — `feat/12-…` on GitHub is `…/issues/12` — so it follows a checkout and is never written.
Removing it on purpose is stored too, so the branch does not bring it back. Only `github.com`,
`gitlab.com` and hosts whose name says `gitlab` are read as forges; anywhere else the ticket is set
by hand. `IssueReference`, which reads a forge's ticket and merge request addresses, is meant to be
shared with #37.

### The agent's tools: an MCP server, bridged over a socket

The agent is started with one more tool server, `vibe-browser`, on its command line and for that
launch only, like its hooks (ADR 0022): `--mcp-config` for Claude Code (which adds to the user's
servers), `-c mcp_servers.vibe-browser.*` for Codex. The server is this application's own binary
given `--browser-bridge <socket>`: a pipe between the agent's standard input and output and a Unix
socket the application listens on, in the terminal host's private directory. The application is the
MCP server; the bridge only carries lines.

A local HTTP server was the other way. It would be reachable by every user of the Mac, so it would
need a secret, and it would fail for good in an agent started while the application was closed. The
bridge starts either way: with the application closed it answers `initialize` and `tools/list`
itself, says so when a tool is called, and connects again at the next call — which is how an agent
left running in the terminal host (ADR 0017) gets its tools back after a relaunch.

Turning off "Give agents the web view" in the settings closes that door too: the channel then lets
no one in, rather than only leaving the tool server off the command line.

The same channel answers `vibe browser …`, a command put in front of the `PATH` of every session's
terminal (a script in the host's directory, written at each launch so that it follows the
application when it moves), for the shell scripts of the agent and of the user.

An agent that shows the user a page the way CLIs do — `open <url>` — shows it in the web view: the
same directory holds an `open` that sends a lone `http(s)` address to the session's web view and
everything else, or a page while the application is closed, to macOS's `open`; `BROWSER` names it
too. The tools' instructions ask the agent to use `tab_open` whenever the user should see a page.

Claude Code is started with `--allowedTools mcp__vibe-browser`: Vibe Manager asks the user itself
before anything is done as them, and a second question for the same call would add nothing.

### Which session: the ancestry of the process, not a secret

The ticket proposed a token in the session's environment. Any process of the same user can read
another's environment (`KERN_PROCARGS2`), and any user can read its command line. What cannot be
made up is where a process comes from: the connection's audit token gives its pid, the kernel gives
each ancestor's parent and start time, and the connection belongs to the session whose agent
process is in that chain — its pid *and* its start time, and every link checked for a parent that
started no later than its child, so that a number given again to another process inherits nothing.
The bridge, `vibe` typed in the terminal, a script the agent runs: all descend from the session's
terminal and are accepted for it alone. A daemon that forked twice and was taken in by `launchd` is
refused: that is the rule's one limit.

Accepting every descendant is a choice (#239), not an oversight: `vibe browser` and `BROWSER` in a
script are features, and a script of the repository could start the signed bridge itself, so
checking the connecting program's signature would guard nothing. What guards the user is that
nothing is read from, or done on, a signed-in site without their answer, and that the answer
cannot be forged outside the application.

An agent sees only its session's tabs. An identifier from another session is answered exactly like
one that never existed.

### What an agent may do without asking

`BrowserActionPolicy`, a pure function over the action, the page's origin and the sites the user
allowed:

| | This Mac (`localhost`, `*.localhost`, `127.0.0.0/8`, `::1`, `file:`) | Anywhere else |
|---|---|---|
| Read — text, snapshot, console, screenshot | free | asked once per site and session, unless "Always Allow" for that site |
| List tabs | free | the title of a site not readable yet is withheld |
| Navigate — open, go to, reload, close | free | free, always in front |
| Act — click, type, JavaScript | free | asked, unless "Always Allow" for that site |

`0.0.0.0`, the local network and `.local` are other machines, or can be. The origin is read from
the parsed address, never from a string — and from the document the page holds, never from where a
navigation is heading: until a navigation commits, the page is still the previous site's, with its
cookies, so an agent that sends a signed-in tab to a local port that never answers gains nothing.
Nothing is done while a page loads. The site is checked again after the user answers, since the
page may have moved while the question was on screen, and once more inside the page
(`location.origin`) in the same turn as the action. A tab cannot be sent to `javascript:` or `data:`; another
application's address, and a download, caused by the agent are asked. A question is a banner in
the session's web view — the session's row says so when it is not on screen — and the agent waits
two minutes at most. "Always Allow" covers clicks, typing, JavaScript and reading on that site; the
sites are listed, and removed, in Settings › Web View.

Reading a site away from this Mac is acting as the user too: the page carries their cookies, and a
private ticket read is a private ticket that can be sent anywhere (#239). Whether a site keeps a
session cannot be told reliably (`HttpOnly` cookies, sessions kept by the server), so every site
away from this Mac is treated alike. `page_read`, `page_screenshot` and `page_console` ask the first
time a session's agent reads a site — "Allow in This Session" or "Deny", no "Always Allow", which
would also let it act — and the site stays readable until the session is archived or the
application quits. The same checks as for acting apply: decided on the document the page holds,
nothing read while it loads, the site checked again after the answer and, for a page's text, inside
the page in the same turn as the read. Until a site may be read, `tabs_list` and the answer to
`tab_open` withhold its pages' titles, and `tabs_list` cuts the address of a tab the agent did not
open to its site: a title says what a private page is about. A page away from this Mac is never
loaded out of sight: `tab_open` with `activate: false`, or `tab_navigate` on a tab behind, brings
it to the front and says so. A preview on this Mac may still wait behind.

Once a site may be read in a session, an agent misled by a page can still carry what it read to
another site by navigating there; the question says what it gives. The tools' descriptions say that
a page is data, not instructions.

The sites always allowed are an item of the user's login keychain (`VaultBrowserPermissionStore`),
which answers the application only: any other program asks macOS, which asks the user. The list the
user defaults held before #239 is erased at launch, not carried over: a site written there by a
script cannot be told from one the user allowed. A keychain that cannot be read allows no site.

### Reading and acting on a page

Snapshot, references, clicks and typing run in a content world of their own, `vibe-agent`: the
page shares its elements with it and sees neither its code nor its references. The console is
caught in the page's world, the only place it can be, so a page can write false lines into its own
console. `page_evaluate` runs in the page's world, which is its point. Clicks and typing are DOM
events (`click()`, the native `value` setter then `input` and `change`, which React follows).
Everything returned is bounded; a screenshot is at most 1 568 pixels on its longer side.

### Seeing what the agent did

The tab an agent opened carries a mark, which shows while it acts; the element clicked or filled is
outlined for 600 ms. `BrowserActionLog` keeps the last 200 actions of a session, reads grouped, in
`Browser/<session-uuid>.trace.json`: a value typed is cut to 80 characters and never kept for a
password, card or one-time-code field; a script is cut to 200; no page text, capture or console is
written.

### A link clicked in a terminal

⌘-click opens a web address in the session's web view, or the default browser as the settings
say, ⌥⌘-click the other way. What a terminal shows is anybody's, and a link's text can differ from
its address: only `http`, `https`, `mailto` and local files that are pages (`html`, `svg`, `pdf`)
are opened. Another application's address or any other file — a `.command`, an application — is
not run on a click.

### ⌘W follows the keyboard

With the keyboard in the web view — the page or its address bar — ⌘W closes its tab, and the File
menu's item says "Close Tab". The page shown next — the neighbour of the tab closed, or the tab
brought forward — takes the keyboard the previous one had, so that ⌘W again closes the next tab:
left to the window, the keyboard was nowhere, and the second ⌘W of a burst closed the session
(#165). ⌘W no longer closes the session anywhere: the session is ⇧⌘W, as the window is in Safari,
and ⌘W, with the keyboard in none of the session's inner elements — the web view, the drawer of
side terminals — is unavailable. On the ticket's pinned tab it beeps. The
web view has its menu: ⌘L, ⌘R, ⌘[ and ⌘], ⌃⇥ and ⌃⇧⇥; ⌥⌘B shows it, ⌥⌘4 focuses it.

### One store of cookies

Every session's web view shares one `WKWebsiteDataStore`, kept on disk and apart from Safari's,
named by an identifier in the data folder: an isolated copy has its own. Signing in once to GitHub
or GitLab signs in every session's ticket tab. Settings › Web View clears it.

## Consequences

- `VibeBrowser` is a module of its own: WebKit, the socket, the bridge and the MCP server, no view.
  `VibeDomain` and `VibeApplication` know neither WebKit nor sockets: the policy, the ancestry
  check, the ticket and the layout rule are tested without a window.
- The one binary is four programs: the application, the terminal host, the bridge and `vibe`.
- A session adopted from the terminal host keeps the command line it was started with: its agent
  gets the tools at its next start.
- A process of the same user can write false console lines into a page it controls, and false
  lines into the trace's file. It cannot reach a session's tabs through the channel, and it cannot
  add an "Always Allow" without macOS asking the user for the keychain (#239).
- A process that descends from a session's terminal speaks for its agent: it gets the same
  questions, nothing more.

## Out of scope

A full browser (bookmarks, global history, extensions, passwords), developer tools beyond what
`page_read` and `page_console` give (Safari's Web Inspector remains in development builds only),
and sharing a tab between sessions.
