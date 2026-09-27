# 0030 — Side terminals, in a drawer of each session

- Status: accepted
- Date: 2026-09-26
- Issue: [#43](https://github.com/hadrienl/vibe-manager/issues/43)
- Amends: ADR 0004's "Terminal output is never persisted", for side terminals only; ADR 0004 and
  ADR 0017's "one terminal per session"

## Context

A session had one terminal, its agent's. Running a server, following a log or typing a `git`
command meant another application, in another window, in a folder found again by hand. #43 asks
for terminals that belong to the session: in a drawer of tabs under it, still running when the
drawer is hidden, and found as they were when the session is reopened or the application
relaunched — tabs, order, folder and what each one showed.

## Decisions

### A terminal is not a session: `TerminalID`

The terminal ports, the supervisors, the terminal host and its protocol were keyed by `SessionID`.
They are keyed by `TerminalID`. The agent's terminal keeps the very UUID of its session
(`SessionID.agentTerminal`), so the host's frozen protocol, its sixteen bytes of identifier and the
runtime document are unchanged byte for byte: a host left running by the previous build is
reattached to as before. A side terminal has a UUID of its own. Callers that speak of a session go
through overloads that name its agent's terminal.

Giving each side terminal an invented `SessionID` was rejected: an identifier that names no session
would have been taken for one by every later piece of code — restoration, journal, activity.

### A role, told apart where it counts

`TerminalSpec` carries a `role`, `agent` or `auxiliary`. It crosses to the host, and comes back in its
list of sessions (additively: a host that predates it lists agents, the only kind it knew). A side
terminal's shell is always "running" — an idle prompt — so it is not counted as an agent: not in
the question asked when quitting, not among the agents a restart of the host for Full Disk Access
waits for (ADR 0010), not in the activity the host holds while agents run. The host refuses to
retire only while an agent runs: a side terminal still open then — one opened on a session whose
agent had ended — is stopped with what it runs, and its tab says so. Nor does a side terminal keep
a host nobody is attached to: once no agent is held there, running or ended and unread, the shells
left with them are stopped and the host leaves, as it would with nothing at all.

A host left running by an earlier build (Keep Running across an update) knows neither the role nor
the trampoline below: it would start the shell without job control and list it as an agent after a
relaunch. A new host says it can with the `sideTerminals` capability; until the old host is gone,
side terminals are started in the application, and stop with it.

### A controlling terminal, through the application's own binary

`posix_spawn` makes the child a session leader and opens the terminal on its standard descriptors,
but on macOS opening a terminal never makes it the controlling one: only `TIOCSCTTY` from the child
does, and no spawn action performs it. Measured: the child shows no terminal in `ps` and a
foreground group of 0. An agent in raw mode never noticed. A shell does: no job control, ⌃C
interrupting nothing — the kernel has no foreground group to signal — and a command running in it
that cannot be told from the shell.

A side terminal's shell is therefore started through the application's binary, as VS Code starts
its terminals through a helper: `Vibe Manager --terminal-exec <path> <argv0> <arguments…>` is the
first thing the entry point looks at; it takes the terminal and `exec`s the shell in the same
process, which keeps nothing of the application but its pid, session and descriptors. The shell
was validated before the spawn, so the helper failing to `exec` it only has its status to give
(127). It refuses (126) unless it leads its session with a terminal on its input, the only way
`PseudoTerminal` starts it; run otherwise, it would give nothing a program run directly does not
have — `exec` replaces the application's image and identity — but it has no reason to run anything.
An agent's terminal is started exactly as before: changing how every agent gets its terminal was
not this ticket's to risk.

Stopping a side terminal hangs up on it, as closing a terminal window does: `SIGHUP` to the shell
and to every job it runs. Under job control each job lives in a group of its own, where a signal to
the shell's group alone would not reach it, and a shell busy with a foreground command, or killed
before it could pass the hang-up on, would leave the others running — measured: a background
`sleep` outlived its shell. So the groups are read from the kernel before anything is signalled:
every process whose controlling terminal this is (`KERN_PROC_TTY`; `KERN_PROC_SESSION` answers
`ENOENT` on macOS). `SIGTERM` and `SIGKILL` follow as for any terminal, and those groups are swept
with the shell's. The grace period is one second: an interactive shell ignores `SIGTERM`, and a session
closing, or an application quitting on its deadline, waits for these stops.

### The history of side terminals is written to disk

ADR 0004 kept terminal output off the disk, and ADR 0017 said so again. #43 asks for the opposite
for side terminals, and gets it, for them only: the agent's terminal is still never written — its
history is the conversation, which the agent keeps, and which #10 replaces with a summary.

- **What**: the raw bytes of the terminal's history, exactly what `attach()` would replay, bounded
  like the history in memory (5,000 lines, 4 MiB). Bytes rather than the text SwiftTerm renders:
  colours are kept, and the replay is the road reattaching already takes.
- **When**: five seconds after output, at most every two minutes per terminal, so that a crash
  loses little without a followed log rewriting up to 4 MiB every few seconds — eight of them would
  write gigabytes an hour; and immediately when the session closes, is archived, or the application
  quits.
- **Where**: `Terminals/<session>/<terminal>.scrollback` beside the store, `0600` in `0700` folders,
  the folder excluded from backups — a history can hold a token a command printed. The diagnostics
  export reads their total size, never a byte of them.
- **Turned off** in Settings › Terminals: nothing is written, and what was is erased.

A history is cut wherever its buffer was trimmed, and may end inside an editor's alternate screen,
with a hidden cursor or a scrolling region. After the replay, a soft reset puts those back before
the separator and the new shell. The programs that wrote it also asked the terminal questions — its
attributes, the cursor's position, its colours — which the view answers as it reads them: while a
restored history is fed, those answers are dropped rather than typed into the new shell's prompt,
and a folder it names (OSC 7) is not taken for the new shell's.

### What a drawer is, and where it is kept

`Terminals/<session>/drawer.json`: the tabs in order, the one in front, each one's name, folder and
size, and whether the drawer is shown and how tall. Never a command line: one can hold a password,
and this document is written whether histories are kept or not. Beside the store and never inside it: those
change all the time, and each change written into `sessions.json` would rewrite it and could touch
the date that orders the sessions. A document that cannot be read is set aside, dated, rather than
overwritten.

The folder a shell is in, and the command it runs, are read from the kernel
(`ShellProcessInspector`): the shell's current directory, and its terminal's foreground group and
that group's arguments — `npm run dev` rather than `node`. OSC 7 is followed when a shell sends it;
zsh does not by default outside Terminal.app. A tab is titled by the name the user gave it, else the
command running, else the folder.

### Following the session

| What happens | Side terminals | Written down |
|---|---|---|
| The drawer is hidden, another tab or session is shown | Nothing stops; only the session on screen has its drawer mounted | Visibility, tab in front |
| The session is closed, archived, or its agent ends | Each history written, then every shell stopped | Kept |
| The agent is switched | Nothing: the shells are the user's, not the agent's | — |
| The session is reopened, or restored after a relaunch | A drawer that was shown comes back with it; a hidden one when it is next shown | — |
| Quit, **Stop All** | Written, then stopped with the rest | Kept |
| Quit, **Keep Running** | Left in the host with their session's agent, and listed in `runtime.json` | Kept |
| Relaunch after **Keep Running** | Taken back as they are, with the agent; one that ended meanwhile is restarted under the history the host kept | — |
| A crash, a restart of the Mac, a host lost | Restarted from the last history written; a shell that outlived its host is found and stopped like an agent, and so are the jobs it ran in groups of their own — found by its terminal session, which they keep after the shell and its terminal are gone | Kept |

A restored tab is a **new** shell, in the folder it was in, under its history and a dated line:
`── Resumed · 26 Sep 2026 at 09:12 · new shell ──`. Nothing is typed into it: no command is ever run
again on the user's behalf. A folder that is gone falls back on the session's, and a session folder
that is gone — a worktree removed — on the home folder, with a line saying which. What a tab shows
above its shell — the history of the shells before it, the separator, that line — is kept with the
tab for as long as the shell lives: replayed by every view rebuilt over it (the drawer hidden and
shown, the session left and come back to), and written with the shell's own output, so that a
second restoration keeps the first. `drawer.json` says how many of the history file's first bytes
it is, for a shell the host kept, whose own history holds only its output.

`exit` at a prompt closes its tab, as Terminal.app does by default; a shell that ends any other way
keeps its tab, with its status, **Restart** and **Close**. A hidden terminal that writes something,
or ends, marks the status bar's button until it is seen. Closing a tab asks first when a command
runs in it, read from the kernel at that moment. Closing or archiving the session names the
commands it stops, and quitting says the side terminals follow their agents.

A restoration, a close and a shutdown never cross: reading the document and restoring its tabs are
each done once and waited for by everything else, and a shell whose tab was closed, or whose
session shut down, while it was starting is stopped as soon as it has started.

## Consequences

- `VibeDomain` learns nothing. `VibeApplication` gains `TerminalID`, `TerminalRole`, the drawer's
  document and store port, `ShellProcessInspector`, `DrawerRestoration` (the fallback of folders and
  what is replayed, decided without a process) and the side terminals of the runtime document.
- `SessionLauncher` stays the one road to an agent, and tells the drawer what happens to its session
  (`SessionSideTerminals`). The drawer starts its own shells through the same supervisor.
- A side terminal is a `TerminalPaneModel` in a `TerminalPaneView`, the agent's own component: what
  the main terminal learns — the file drops of #42 among them — the side terminals have.
- A session opens at most eight side terminals: the host runs 64 terminals at once, agents included.
- Deleting a session is not a verb of V1 (ADR 0009); the store removes a session's drawer the day it
  is.

## Rejected alternatives

- **A trampoline for every terminal.** Agents run in raw mode and handle ⌃C themselves; giving them a
  controlling terminal changes how every one of them is signalled, for no reported problem.
- **`script(1)` as the trampoline.** It allocates a second pseudo terminal inside the first, and does
  not pass a resize on.
- **Persisting the text SwiftTerm renders.** Loses colours and formatting, and needs a second way to
  replay a terminal.
- **Keeping every session's drawer mounted**, as the agents' terminals are: a full surface weighs
  about 17 MB (#19), and ten sessions of three tabs would weigh half a gigabyte for views nobody
  looks at. The host keeps their history; a drawer shown again replays it.
