# 0017 — A terminal host, so the agents can outlive the application

- Status: accepted
- Date: 2026-09-24
- Issue: [#58](https://github.com/hadrienl/vibe-manager/issues/58)
- Supersedes: ADR 0011's "An agent does not outlive the application that spawned it", and ADR
  0004's "Multi-process coordination is out of scope: a terminal does not survive the application"

## Context

Quitting stopped every agent, on purpose, for three reasons that added up. The application owned
the master of every pseudo terminal, so its death closed them. `PrepareForQuit` stopped each session
before closing it in the store (ADR 0011). And `TerminalProcessGroupGuard` killed, from `atexit`,
every process group still registered, as the last line against orphans.

#11 made a quit cheap by resuming each agent natively at the next launch: the conversation comes
back, but the turn in progress is lost, along with everything the terminal showed. #58 asks for the
other answer: quit, for an update or by mistake, without interrupting an agent that has been
working for twenty minutes, and find it again as it was.

Three facts of the code made that possible without rewriting it. The terminal was already behind
ports — `TerminalSupervisor`, `TerminalSession`, `TerminalAttachment` — and `SessionLauncher` knew
nothing else. `attach()` already answered a late subscriber with the bounded history and the live
stream as one value, which is exactly what reattaching after a relaunch needs. And
`PTYTerminalSession` already did everything but survive the process it lives in.

## Decisions

### The host is the application's own binary

`Vibe Manager.app/Contents/MacOS/Vibe Manager --terminal-host <directory>` is the terminal host. The
entry point turns to `TerminalHost.runIfRequested()` before anything of the application is set up,
so in that mode there is no `NSApplication`: no Dock icon, no menu bar, no window.

A second executable was rejected. Being the same signed binary settles the three questions the
ticket asked to check before designing anything:

- **TCC** sees the same code identity, and the Full Disk Access granted to Vibe Manager covers the
  host (below).
- **Peer verification** needs no team identifier written anywhere: each end requires of the other
  its own designated requirement, which is the same one.
- **Distribution** gains nothing to sign, notarize (#19) or copy into the bundle.

`PTYTerminalSession`, `TerminalHistory` and `TerminalProcessGroupGuard` moved into the host
unchanged. The application no longer spawns an agent itself, except in the fallback below.

### Spawned by the application, not registered with `launchd`

| | Spawned by the application | `launchd` agent through `SMAppService` |
|---|---|---|
| What the user sees | nothing | a "background item added" notification, an entry in Login Items, revocable |
| When it starts | at the first terminal | registered, then activated on its socket |
| Surviving the application | `POSIX_SPAWN_SETSID`: a session of its own, no controlling terminal, nothing the application's death sends reaches it; it is reparented to `launchd` like any orphan | native |
| Surviving a logout or a restart | no | no |

`launchd` offered nothing this needs. The host has no reason to exist before the application first
opens a terminal, and must not come back after a restart, which is out of scope. A registered agent
would cost a visible, revocable item for neither. The host is spawned with
`POSIX_SPAWN_CLOEXEC_DEFAULT`, its standard descriptors on `/dev/null`, and an environment of a
handful of variables: every agent it starts is given the environment the application computed for
it, inside its `TerminalSpec`.

### One host per data directory

The socket and the lock sit in `$(getconf DARWIN_USER_TEMP_DIR)/vibe-manager/<16 hex digits of the
SHA-256 of the data directory>/`. That directory is private to the user, created `0700`, and short
enough for the 104 bytes of `sun_path`, which `~/Library/Application Support` does not guarantee.
An isolated copy of the application (`VIBE_DATA_DIRECTORY`) has its own store and its own runtime
document, so it has its own host as well.

The host takes an exclusive `flock` **before** binding its socket. A host that finds the lock held
is a second one, and leaves without touching the socket the first one is listening on. A socket
found while the lock is held is a leftover of a host that is gone, and is removed.

### The protocol: a frozen core, and capabilities for the rest

A frame is a big-endian `u32` length, a `u8` kind and a payload of at most 1 MiB. Control messages
are JSON, so a capture can be read by hand like `runtime.json`. Keystrokes and output travel raw,
behind the sixteen bytes of their session: encoding every burst as JSON would cost a copy and a
third more bytes for nothing.

| Application → host | Host → application |
|---|---|
| `hello(protocolVersion, build, capabilities)` | `welcome(protocolVersion, build, capabilities, pid, startedAt)` or `refused(reason, otherClient \| incompatible)` |
| `list` | `sessions([session, state, endedAt])` |
| `start(session, spec)` | `started(pid)` or `startFailed(TerminalError)` |
| `attach(session)` | the history as `output` frames, **then** `attached(state, droppedByteCount)`, then the live stream |
| `input` (raw) | `output` (raw) |
| `resize(session, size)`, `redraw(session)` | `state(session, state, endedAt)`, `truncated(session, bytes)` |
| `stop(session, grace)`, `kill(session)` | `stopped(state)` |
| `release(session)`, `goodbye(keepRunning)` | `done` |

- **The history comes before `attached`.** When the reply arrives, everything the host held for
  that session is already in the application's buffer. A session that ended while the
  application was closed can therefore be shown whole, and then released.
- **Terminal bytes are cut to the frame.** The reader coalesces up to 4 MiB of output, and a paste
  can be as large. Sent as one frame, either would exceed what the other end accepts, and the
  closed connection would read, to the host, as a crash of the application.
- **`stopped` leaves after the session's last output and final state**, never before. The client
  ends its stream on the reply: anything after it would be lost, or would reach the next process
  started under the same session.
- **`startedAt` is the kernel's**, read with `sysctl` on the host's own pid, not the host's clock.
  The host is a whole application binary and takes a while to reach its first line, longer still
  when the system assesses it. The application confronts that instant with a second's tolerance.
- **One client at a time.** A second `hello` is refused, whatever `runtime.json` says: a second
  copy of the application can neither read nor type into the first copy's terminals.
- **A slow client never slows an agent.** The reader of the pseudo terminal keeps its own
  back pressure in the host, unchanged. Each client subscription is the session's own bounded
  stream: a client that stops reading holds the task that forwards to it, and the stream drops its
  oldest output and says how much, as it always did for a subscriber that fell behind.
- **Stops leave the client's loop.** A grace period paid inline would hold every keystroke
  behind it.
- **Versioning.** The core above is frozen: every future application speaks it, so a host left
  running by an older build can always be reattached to. New messages are negotiated as
  capabilities. If the core ever had to change, the socket would change name with it
  (`host-v2.sock`). The new application would start its own host for new sessions, and speak the
  old core to the old host only for its sessions, until it empties and leaves. Handing masters from
  one host to the other over `SCM_RIGHTS` was rejected: the new host would not be the agents'
  parent, and could never learn how they exited.

On the application's side, `HostedTerminalSupervisor` is a `TerminalSupervisor`. Each
`HostedTerminalSession` keeps its own replay buffer, fed by the host. Every `attach()` the
application makes — pane, surface, exit watch, agent observer — is answered locally, exactly as
`PTYTerminalSession` answers it. Nothing above the supervisor can tell the two apart.

### Left running only when asked

The host keeps a session after its client has gone only if the client said so, with
`goodbye(keepRunning: true)`. A client that vanishes has crashed or been killed, including a stop
from Xcode, and the host stops everything, exactly as the death of the application always did.
ADR 0011's argument stands: the agent's output may be what brought the application down, and
replaying it into the next launch unasked would bring that launch down too. Keeping the agents
alive across a crash is a possible later ticket, not this one.

### Gone when idle

With no session and no client for five seconds, the host unlinks its socket and exits. A session
that ended while nobody was attached counts as a session until a client has read its last output
and released it, or for 24 hours, whichever comes first: an application never reopened must not
leave a host behind for the rest of the login.

A host that cannot take the lock waits two seconds before giving up, because the previous host may
be leaving, idle, at that very moment. For the same reason the application tries twice to start
and reach a host before running its terminals in-process for the rest of the run. That output stays in memory, bounded like any history (4 MiB), and is never
written to disk: ADR 0004's rule against persisting transcripts is unchanged.

While a session runs, the host holds
`ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`. A process started outside
LaunchServices is not a candidate for App Nap, but the assertion also sets the QoS, and keeps timer
coalescing from slowing the reading of a terminal an agent is writing to. The Mac may still go to
sleep, as it could before.

`SIGTERM` and `SIGINT` stop every session, then the host. `SIGHUP` and `SIGPIPE` are ignored. On
both sides, every socket is `SO_NOSIGPIPE`: a peer that disappeared is an error to handle, never a
signal that ends the process.

### TCC: who answers for the agent

Before this ADR, the agent was a descendant of Vibe Manager, which was its responsible process
(ADR 0010). Every protected access was asked for, and granted, in the application's name.

A host spawned the ordinary way would answer to the application's pid, and that pid dies when the
application quits, while the agents go on reading the user's folders. What `tccd` does with a
responsible process that has exited is documented nowhere. That behaviour is **avoided rather than
relied on**: the host is spawned with `responsibility_spawnattrs_setdisclaim(attributes, 1)`, so it
answers for itself, and the agents it spawns without a disclaimer answer to it. Because the host is
the application's binary, its code identity is Vibe Manager's (`com.hadrienl.VibeManager` and the
same designated requirement). The answer to "who does TCC hold responsible" is therefore **Vibe
Manager**, before and after the application quits, and the Full Disk Access granted to it keeps
applying.

ADR 0010 refused this disclaimer for the **agents**, because a command-line binary made
responsible for itself is refused access without being asked. That refusal still holds: the
disclaimer here goes to the application's binary, not to a CLI.

`responsibility_spawnattrs_setdisclaim` is private, stable since macOS 10.14, and used by Chromium,
iTerm2 and VS Code. It is looked up with `dlsym` rather than linked, so a system without it spawns
the host as before instead of failing. The application is not meant for the Mac App Store
(ADR 0001).

Measured while building this:

- **Disclaiming changes the first launch of a new binary.** A freshly linked binary that answers
  for itself waits for the system to assess it — seconds after a rebuild — where the same binary
  spawned without the disclaimer starts at once. The application's host is the binary already
  running, assessed before it ever opened a terminal. The launch timeout is ten seconds anyway,
  and the tests that spawn a freshly built fixture wait thirty.
- **Still to measure by hand, with Full Disk Access granted and then revoked:** an agent reading
  `~/Documents` after the application has quit, with
  `log stream --predicate 'subsystem == "com.apple.TCC"'` running, to confirm the attribution
  chain names Vibe Manager. If it did not, the fallback would be a minimal helper `.app` in
  `Contents/Library/`, with its own usage descriptions, and #31's step asking for both.

### Who may talk to the host

- The directory is `0700`, the socket `0600`.
- On every connection, the host requires the same uid (`getpeereid`). It then reads the peer's
  audit token (`LOCAL_PEERTOKEN`) and checks, with `SecCodeCopyGuestWithAttributes` and
  `SecCodeCheckValidity`, that the peer satisfies the host's **own** designated requirement.
- The application checks the host the same way before sending a byte. A program that bound the
  socket first is handed neither a keystroke nor an agent's environment.
- The audit token is used rather than the pid, which could be worn by another process between the
  moment it is read and the moment it is checked.
- **Signed by a team**, the requirement is the designated one: that bundle identifier and that team.
  Both survive an update, so an application updated while its agents ran reattaches to them.
- **Signed ad hoc** — a development build — it is the bundle identifier alone. The designated
  requirement of such a build is its own hash, which the next build does not have: requiring it
  would kill every agent left running at each compilation, and carrying one's work across builds
  is precisely what this host is for. The identifier lets through a process of the same user signed
  ad hoc under that name; such a process can already open the terminal devices the user owns, or
  rewrite the development binary itself, so nothing is given away that was not already.
- **A binary replaced on disk** — a rebuild, an update — makes `SecCodeCheckValidity` fail with
  `errSecCSStaticCodeChanged` on the host that was started from it, since that call also checks
  the file against the running process. That host is the very one to keep. On that error, and only
  on it, the check falls back on what the kernel says of the running process through
  `csops_audittoken`: a valid signature, the same identifier and, when the application has one,
  the same team. It is what the process was launched as, validated then.
- Measured on a development build: the host kept its session across the replacement of its
  binary; the check by audit token then failed with `-67034`, which is what made a relaunch after a
  rebuild kill the agents it was meant to take back. With the fallback it passes, while a process
  signed under another identifier is still refused.
- **What this does not cover:** a process of the same user can already open `/dev/ttysNNN`, which
  the user owns, and read from it. That is true of every terminal on macOS, and this design does
  not make it worse. "A third-party process can neither connect to the host nor read a terminal"
  holds *through the host*.

### Quitting: a question, then one of two roads

`applicationShouldTerminate` asks only when an agent runs in the host:

> **Agents are running in 3 sessions.**
> You can leave them working in the background and find them as they are the next time you open
> Vibe Manager. A restart of the Mac stops them.
> [Keep Running] [Stop All] [Cancel] ☐ Don't ask again

"Don't ask again" records the answer given. Settings offers **When quitting with agents running:
Ask / Keep them running / Stop them** (`UserDefaultsQuitPreferences`). When
`NSWorkspace.willPowerOffNotification` has been received — a logout, a restart, a shutdown — nothing
is asked. An alert would hold the logout up, and the host would not survive it anyway, so the
application stops everything, which #11 already knows how to resume. The six-second shutdown
deadline starts after the answer: it bounds the tidying, not the time the user takes to decide.

**Stop All** is `PrepareForQuit`, unchanged, followed by `goodbye(keepRunning: false)`. The host,
with no session and no client, leaves after its grace period.

**Keep Running** is `DetachForQuit`:

1. The restoration under way is cancelled and waited for, as before.
2. `SessionHandOff.handOff` is asked of each running session. `SessionLauncher` answers yes for a
   `HostedTerminal` that is still running. It retires the exit watch, so the store is not told of
   an exit nobody here will see, and finishes the agent observer. **Nothing is written to the
   store**: those sessions are active, because they are.
3. What could not be handed off — a terminal in the fallback — is stopped and closed as a plain
   quit would, and named in the document's `resuming`.
4. `runtime.json` is written `detached`, with the host's identity and, for each session left
   running, its process group and the instant it started.
5. Only then `goodbye(keepRunning: true)`. Dying between 4 and 5 leaves a host that stops
   everything when its client vanishes, and a document whose host is then missing, which reads as
   the crash it was. The other order would leave agents running under a document that does not
   mention them.

Steps 4 and 5 come **before** step 3's stops: those pay a grace period, and the application quits
on its deadline whether or not they are done. A goodbye that never left would make the host stop
the very agents the user chose to keep. The document names what is about to be stopped as the
intention to resume, and is narrowed afterwards to what really closed.

### Relaunching: the fifth verdict

`runtime.json` goes to schema 2. It gains the `detached` phase, `host` and `resuming`, and schema 1
is still read. A build that only knows schema 1 reads a schema 2 document as nothing to honour: it
reconciles the store and **offers** the sessions, which is the safe way to downgrade.

`DetectPreviousShutdown` asks the host (the `TerminalHosting` port) before anything else is decided.
A session the host still runs is the one thing in the store that `active` is true of, and the
reconciliation must not close it.

| Found | Verdict | What happens |
|---|---|---|
| `detached`, host connected and verified | `detached(running, ended, resume)` | running sessions are **adopted**; one that ended while away is closed, dated from when the host saw it end, and shown with its last output; `resuming`, and what the host lost, are resumed as a clean quit would |
| `detached`, no host, **and the Mac restarted since** (`kern.boottime` after the quit), **or the host said it was told to stop** (a logout, a shutdown, `kill`) | `clean` | resumed natively (#11): leaving them running was an intention to carry on that the system cut short, which is not a crash |
| `detached`, no host, and nothing says why | `unexpected` | the host crashed or was killed outright: the sessions are **offered**, and their process groups are looked for as leftovers first |
| `detached`, a host that is ours but will not answer now (another copy attached, no reply in time, no list) | `hostUnavailable` | nothing is decided: neither the store nor the document is touched and nothing is killed. A banner says the agents are still running and offers **Retry**, which runs the detection again |
| `detached`, a host that will not verify (another build) | `unexpected` | the host is killed once its identity is confirmed, its agents' groups too, and the sessions are offered |
| anything else | ADR 0011's four | unchanged |

Adopting a session starts nothing, sends nothing and writes nothing (`SessionLauncher.adopt`). The
pane takes over the terminal (`TerminalPaneModel.adopt`), the exit watch and the record of its
process group are armed again, and the surface replays the history and follows the live stream.
The first size the view reports is followed by a `redraw`: `SIGWINCH` to the group the child leads.
The kernel raises nothing for a size that did not change, and a full-screen program redraws itself
for the window it is now in rather than showing a history cut wherever the buffer was trimmed.

A host told to stop — `SIGTERM` or `SIGINT`, which is what a logout or a shutdown sends — writes
the instant into `stop-requested`, next to its socket, **before** giving its agents their grace
period, since the system may not wait for it. A host that crashes writes nothing. The next launch
reads that file when it finds no host; the next host deletes it once it holds the lock, by which
time the application has already looked.

A banner says it once: "3 agents kept running while Vibe Manager was closed; 1 has finished since."
When nothing has finished it goes away by itself, since there is nothing to act on.

A `start` the host does not answer in time, from a host still connected, is not retried in the
application: the host may have started the agent, and a second one would work in the same folder.
It is killed, and the launch fails.

### When the host cannot be used

When the host cannot be started, or will not prove it is ours, the terminal is started in the
application exactly as before this ADR. It will stop with the application, and it says so where
the agent is: a bar above the terminal reads "This agent will stop when Vibe Manager quits." The
question asked on quit counts only the agents that can be left, and names the others as stopping
either way. A broken helper the user never sees must not keep anybody
from working. `VIBE_TERMINAL_HOST=off` starts no host, which keeps a development build's agents
inside the process a debugger is attached to.

## Consequences

- `VibeDomain` learns nothing. `VibeApplication` gains ports — `TerminalHosting`, `SessionHandOff`,
  `QuitPreferences` — and knows no socket, no process and no signature: the verdicts and the
  detached quit are tested without any of them.
- `VibeTerminal` holds the wire, the server, the client and the launcher. The same server runs in
  the tests on a socket of their own, and in a process of its own through
  `VibeTerminalHostFixture`, an executable target built only for the tests.
- `SessionLauncher` gained `adopt` and `handOff`. It is still the one road to a process: the host
  is behind the supervisor it was always given.
- `TerminalSpec`, `TerminalProcessState` and `TerminalError` are `Codable`, because they cross the
  wire as they are.
- Three limits are deliberate:
  - No separator is written above an adopted terminal: the surface writes a pending notice
    **before** the history, where it would date the wrong output.
  - An adopted agent is not observed again: the observer needs the launch plan, and a Codex
    identifier not yet captured when the application quit stays uncaptured.
  - The status bar's own restart does nothing on an adopted pane, which has no spec of its own;
    **Restart** in the Session menu is the way, as for any closed session.

## Out of scope

Surviving a restart of the Mac or a logout (#11 covers it). Keeping the agents alive when the
application crashes rather than quits. A menu bar icon, and notifications sent by the host while
the application is closed (#40, #45). The side terminals of #43, which are to use the same host
once it is in place.
