# 0011 — Restoring sessions after a relaunch

- Status: accepted
- Date: 2026-09-22
- Issue: [#11](https://github.com/hadrienl/vibe-manager/issues/11)

## Context

#10 gave a closed session its way back to work, and said so in one line: restarting never creates
a second session and never loses the first. This ticket changes who presses the button. The caller
is now the launch of the application, and the whole of the work is deciding **which** sessions to
resume, **when** to refuse to, and **how** to say it.

The state it inherits is a lie: quitting stopped every process and left every session stored
`active`. #10 named that as #11's problem, and it is the right place to start, because the fix is
also the design.

## Decisions

### The store never claims that a process is running

An agent does not outlive the application that spawned it: it is its child, it shares its pseudo
terminal, and nothing in `sessions.json` can be true about a process once that process is dead. A
session stored `active` with nothing behind it is therefore not a state to handle but a statement
to stop making. Two gestures remove it:

1. **At the exit**, every running session is stopped, then closed in the store, and its identifier
   is left behind as the intention to resume it (`PrepareForQuit`).
2. **At the launch**, every session the store still calls `active` is closed, because nothing can
   be running — this application is the only thing that runs these processes and it has just
   started (`DetectPreviousShutdown`).

After those two, resuming is no longer a special case: it is `RestartSession` on a closed session,
with not one of its rules rewritten. #11 owns the queue and the verdicts; it owns none of the
launching.

### A runtime document, next to the store and nothing like it

`sessions.json` is unchanged, still schema v2. "The same repository, provider, remote identifier
and metadata come back" is true because the restart **re-reads the session**, not because anything
copied its fields somewhere else.

What this launch is running lives in `runtime.json` beside it: the phase (`running` / `stopped`),
the pid of the instance that wrote it, and one record per running session with its process group
and the instant the kernel says that group started.

- **Separate, versioned on its own, no backup.** Every way of failing to read it answers `nil`,
  which means "no intention to honour". A damaged record of one launch must never be able to make
  the sessions themselves unreadable, and losing it costs a manual restart.
- **Not in the user defaults**, where #8 keeps the layout: `cfprefsd` writes when it decides to,
  and this document's last write happens immediately before the application dies. It is written
  through `fsync` and replaced atomically.
- **Written on events, never on a timer.** A heartbeat would buy nothing: after a crash the
  sessions to resume are already in the store, as the ones left `active`. The document exists to
  tell a quit from a crash, and to remember which process groups to look for.

### Four verdicts, and only one of them resumes on its own

| Verdict | Read from | What happens |
|---|---|---|
| `nothingToDo` | no document, or `stopped` with an empty list | nothing |
| `clean` | `stopped` with sessions | they are resumed, with progress and a way to cancel |
| `unexpected` | `running`, pid dead | the store is reconciled, leftovers are dealt with, and the sessions are **offered** |
| `otherInstance` | `running`, pid alive | nothing is reconciled and nothing is claimed |

A clean quit resumes by itself, because quitting with sessions running *is* the intention this
document exists to carry; asking again at the next launch would charge the user twice for one
decision.

An unexpected stop offers instead. A crash is not an intention, and the agent that was running may
be what brought the application down — relaunching it unattended, with nobody in front of it, is a
crash loop that restarts five agents each time round. It is also what makes the detection visible,
which the ticket asks for in as many words.

`running` with a **living** pid is not a crash at all but a second copy of the application. Taking
the document would take its sessions, and reconciling the store would close sessions that really
are active, so neither happens and the banner says why. Our own pid read back is the same launch
asking twice, and answers `nothingToDo`: the sessions that are active by then are the ones this
instance has just started.

"Living" is not "a pid that answers". The document records the instant the kernel says that
instance started, and the two are confronted: a pid worn by some other long-lived program after a
crash would otherwise read as a second copy at every launch — the store never reconciled, nothing
ever restored again — and one that happened to equal ours would make a crashed run look like this
very launch. A pid that answers but cannot be identified at all is treated as a living instance,
which is the conservative half of the two mistakes: taking sessions from a copy that is working in
them would close them under its own agents, while refusing to take them says so in a banner.

### The intention is consumed before the first resume

`DetectPreviousShutdown` claims the document for this instance as soon as it has read it. That is
what makes "restarted exactly once" true even if the application dies in the middle of a
restoration: what did not come back is left as closed sessions, which Restart puts to work one
gesture at a time. A queue that could be replayed would multiply agents on every unlucky launch.

### A restoration never sends a text to an agent

Only a native resume is restored, because it is the only mode that sends nothing at all.
`needsConfirmation == false` was nearly that rule and not quite it: `firstLaunch` confirms nothing
either and hands over the initial prompt — days later, on a session that has moved on.

The consequence is deliberate. Such a session appears in the report with its own sentence — "Stub
Agent kept no identifier for this session" — and its **Restart** command, which leads to #10's
editable summary. A summary handed to an agent at launch, with nobody having read it, is precisely
what #10 refused to do quietly; doing it five times while the user is still opening their laptop
would be worse.

Archived sessions, unknown agents and vanished folders need no code here: they are `RestartSession`
refusals, reported with the remedy it already writes. An identifier that names nothing at all is
filtered out before the count is spoken — "3 sessions were running" has to be three sessions the
user can see.

### One session at a time, and cancellable between two

Each resume opens a pseudo terminal and starts a CLI that reads its own configuration and history.
Five at once, on a cold disk, is an application that does not answer during its own restoration —
and a queue is the only shape that can be called off between two items without stopping anything.

The order is most recently worked first, and the two paths reach it differently. A clean quit
closes its sessions in that order, so the document's own list already is the order to come back in.
A crash wrote nothing in any order — the records are appended as sessions *start* — so the
identifiers are sorted against the store, read before the reconciliation writes a fresh
`updatedAt` on every one of them. Either way, the session the user was in does not come back last.

Cancel empties the queue and touches nothing that is already running: stopping an agent that has
just been handed its conversation back, in order to honour a cancellation, would destroy the very
work this was restoring. Quitting mid-restoration cancels it too, and then runs the ordinary exit.

Failures never interrupt the queue — an unavailable provider is the normal case, not an incident —
and everything that did not come back is gathered into one collapsible report, one line per
session with its sentence and its remedy. Never a dialog, and above all never one dialog per
session: five modal questions at launch is an application nobody can use. A restoration where
everything came back says nothing at all.

### Quitting is bounded in time, so the stops are paid concurrently

The stops run in one task group, for the same reason `PTYTerminalSupervisor.stopAll` already did:
each one waits out a three-second grace period, and a quit paying them one after another costs as
many seconds as there are agents. Past the deadline the application gives itself, the reply leaves
without the intention having been written — and a deliberate quit is then read as a crash at the
next launch, which is the one outcome this whole design is meant to tell apart. The closures still
happen after every stop, and still in the order the sessions will come back in.

A restoration under way is cancelled *and waited for* before any of this: cancelling only asks,
and a resume already in flight goes on to write `reopen`. That write landing after the shutdown
had read what to close left exactly the ghost this ticket removes.

`applicationShouldTerminate` already replied `terminateLater`, and waited forever. An agent that
ignores `SIGTERM`, and whose `SIGKILL` the kernel is slow to reap, was enough to make an
application that would not quit — a worse failure than the orphan the wait was avoiding. The reply
now comes either from the shutdown or from a six-second deadline, whichever arrives first, and
`TerminalProcessGroupGuard`'s `atexit` remains the last resort. Asked a second time, once that
reply has been consumed, it answers `terminateNow` rather than waiting for an answer nothing is
left to send. A `SIGKILL` runs no code of ours
at all: the children share the pseudo terminal, its closing sends them `SIGHUP`, and whatever
survives is **found and said at the next launch** rather than passed over.

### A leftover is signalled only when its identity is confirmed

Leftovers are dealt with **before** the document is claimed, and that order is not incidental: the
sessions survive a crash in the store, while the process groups survive nowhere else, so claiming
first and dying a moment later would lose their identity for good. A group's record is likewise
dropped only once its process really is stopped — dropped beforehand, a `SIGKILL` landing inside
the grace period would leave a live group whose identifiers had just been erased.

Pids are recycled. A group recorded with the instant the kernel says it started can be recognised;
one that answers but cannot be identified is reported and left strictly alone, because tidying up
on the strength of a number would kill somebody else's program. A group whose start time differs
is not ours at all and is not even mentioned.

## Consequences

- `VibeDomain` and `VibeApplication` still know nothing of SwiftUI, AppKit or SwiftTerm. The
  runtime document, the liveness of a process and the launching of a terminal are three ports, so
  the verdicts, the reconciliation and the queue are all tested without a disk, a process or a
  window.
- `SessionLauncher` gained one thing only: it records the process group of what it starts, and
  answers `attemptRestart` for the queue. There is still one road to a process.
- `sessions.json` is untouched. The only new file is `runtime.json`, which a user may delete at
  any time; the next launch then simply restores nothing.
- A session closed by the reconciliation is dated from the last instant the previous run is known
  to have been alive, not from the moment the application was reopened.
- The launch sequence takes its lock before it suspends. `state` only becomes `.loading` several
  awaits later, so two loads — a second window, a `.task` run twice — both used to pass that
  guard and both detect the same shutdown before either had claimed the document.

## Out of scope

A preference for restoring at launch — the cancel button and the offer after a crash are the V1's
answer, and a remembered "no" is a preference that belongs with the other preferences. Reattaching
to a process that survived the application, which would take a daemon. Persisting the terminal
scrollback (#9, still true here: the terminal comes back empty, with #10's dated separator for
memory). Restoring across several windows or instances, and several repositories per session
(#12). Restarting an archived session, which still requires unarchiving it first (#9).
