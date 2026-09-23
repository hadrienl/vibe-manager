# 0013 — The live state of each repository, read when the disk says it moved

- Status: accepted
- Date: 2026-09-23
- Issue: [#13](https://github.com/hadrienl/vibe-manager/issues/13)

## Context

The branch report of ADR 0012 finds the repositories a session worked in — the folder it was opened
on, and those its transcript names — and says, of each, the branch checked out and how it moved.
Of the files it knew one bit: whether something was left uncommitted since the session started. It
was read every 30 seconds while the agent ran.

This decision gives each of those repositories its full state, reads it off the main thread, and
replaces the timer with the file system's own events.

## Decisions

### Git is the only source, and reading it writes nothing

One command, always the same:

```
git --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=normal --find-renames
```

- `--porcelain=v2 -z`: stable across versions, parsed without heuristics, and NUL separated so a
  path may hold a new line, a quote or a tab.
- `--no-optional-locks`, on top of the `GIT_OPTIONAL_LOCKS=0` the runner already sets: a plain
  `git status` rewrites the index to refresh its stat data and takes `index.lock` to do it — the
  agent committing at that moment would fail on a lock that is ours. A test holds `index.lock`,
  reads, and checks that the index is byte for byte and date for date what it was.
- `--branch` gives the branch, its upstream and the distance between them in the same process.
  Nothing is fetched: the distance is the one the local references say.
- `--untracked-files=normal`: a folder nothing in which is tracked is **one** entry (`build/`).
  An unignored `node_modules` would otherwise be eighty thousand lines.
- Renames are those Git reports, in the index. A move Git was not told about is a deletion and an
  untracked file, and is shown as such: pairing them ourselves would show a state `git status`
  does not confirm.
- The user's configuration is read and never written: a repository with `core.fsmonitor` benefits
  from it; the application enables nothing.
- An operation left half done — rebase, merge, cherry-pick, revert, bisect — is read from the
  files Git leaves in its `git-dir`, since `status --porcelain` does not say it.
- 30 seconds at most per reading, through a runner of its own.

### What an entry says

Git describes a tracked file with two columns, index and working tree, and a file staged then
changed again (`MM`) is both. `WorkingTreeEntry` keeps the two (`staged`, `unstaged`) rather than
one status. Conflicts, untracked files, untracked folders and submodules each have their own case.

Paths are relative to the root of the repository, exactly as Git wrote them: they are the key a
list keeps its selection by. At most 5 000 entries are kept; the counts go on past the limit and
stay exact, and the state says it was cut.

### Which repository, which session

The repositories are those of the session's branch report: this decision does not find them again,
it watches them. The key of a state is the session and the canonical root of the repository.

`git status` says a file changed, never who changed it. The transcript names the files the agent's
editing tools wrote, so each entry says whether **this** session's agent touched it. A file it does
not name is *unattributed*, never attributed to another session: a command the agent ran (`sed`, a
formatter, `npm install`) writes files no transcript names. When another session's last report
names the same repository, the state says so, because the unattributed files may be its work.

### Reading when the disk says so

- FSEvents watches, per repository: its folder, its own `git-dir` — outside the folder for a
  linked worktree — and the references of its `git-common-dir`; and the folders the session's
  transcript is written in. A commit touches nothing in the working tree: without the `git-dir`, a
  commit would not clear the list.
- An event is routed to the **deepest** watched folder: a worktree the agent made under
  `.claude/worktrees` belongs to itself, and writing in it does not read the clone around it.
  Git's objects are ignored; they say nothing a reference does not.
- One reading at a time per repository. Events that arrive during a reading, or during the pause
  after it, ask for **one** more. The pause is `max(1 s, 2 × the last reading)`, at most 15 s: a
  repository that answers in 3 s is never read more than once every 6 s, and a burst of ten
  thousand events costs two readings.
- At most two readings at once in the whole application.
- Events the system dropped are answered with a full reading.
- A moved branch or a grown transcript also says the branch report is out of date, and it is read
  again, one reading at a time with one more for whatever asked during it, after a pause of
  `max(1 s, 2 × the last reading)`: an agent streaming its transcript asks many times a second.
  The 30 second timer of ADR 0012 is gone, and so is every other way to read a report: the refresh
  button goes through the same queue, so an older report can never land after a newer one.
- A transcript folder holds the transcripts of every session opened in the same place: only the
  files named after this session's identifier count.
- The whole transcript folder of the agent is watched — `~/.claude/projects`, or Codex's
  `sessions` — not the folders its files are in. A session selected before its agent wrote
  anything has no file yet, and a Codex session writes in the folder of the day, which changes at
  midnight: a narrower watch would miss the transcript exactly when it starts to grow.
- A watch whose folders change is replaced by a new stream, which starts from now: what the old
  one had not delivered is lost, so the repositories it watched are read once more.
- A clone and a worktree of it watched together share their references: a reference that moves in
  the clone's folder reads both.
- Readings without an event: when a session is selected, when the application comes back to the
  front (a sleep, an unmounted volume), when an agent stops, and on the inspector's refresh button.
  Gestures, not a timer.
- Only the session on screen is watched, as in ADR 0012. Leaving it stops its streams at once,
  even before the next session's report is read; its states stay, marked as no longer watched.
- A repository whose `git-dir` could not be found when it was added (a volume away) has it looked
  for again after its first successful reading.
- Event paths are compared with the watched folders as `CanonicalPath` spells them: FSEvents
  reports `/private/var/…`, which Foundation spells `/var/…`.

### Off the main thread

Running Git, parsing, comparing and attributing happen in the `RepositoryStatusMonitor` actor and
the runner's queue. Only the states that changed cross to the main actor — a reading that only
moved the clock is not published — so the inspector redraws what moved and nothing else. A test
parses 200 000 entries while measuring how long the main actor goes without running.

### Failures keep what was true

A state carries `lastValid` and a phase. A failure sets the phase and never clears `lastValid`; the
next success clears the failure. The same failure keeps the moment it started — a timeout counts
as the same one whatever it measured — so a lock held for two minutes is said as such and is not
published again at every reading. The sentence that says a lock's age is rebuilt every 30 s.

| Seen | Said as |
|---|---|
| Folder gone or moved (FSEvents `RootChanged`, or absent) | missing — nothing is searched for or repaired |
| Not a repository any more | not a repository |
| `index.lock` held | nothing for 10 s; past that, locked, with its age and the `rm` to copy |
| Permission | permission denied, with Full Disk Access as the remedy |
| `dubious ownership` | unsafe repository, with the `safe.directory` command to copy |
| Git missing, or the Xcode stub | `GitUnavailable` of ADR 0012 |
| 30 s exceeded | timed out, and the pause goes to its maximum |

Git's sentences are recognised in English: the runner runs Git with `LC_ALL=en_US.UTF-8`. A command
offered to copy is escaped for the shell and never run by the application. Nothing is modal: a
repository that cannot be read is the business of its own line.

A lock nobody removes sends no event. When a reading finds `index.lock` younger than the grace, one
more reading is set for the moment the grace runs out — the only delay in this decision, and one
tied to something seen, not a clock.

### Presentation

Under each repository of the Git section: the counts in words ("2 staged · 1 unstaged · 3
untracked"), how many of them the transcript does not name, the distance from upstream, an
operation in progress, the other sessions working there, and a failure with its remedy and command.
The header says "live" when every repository is watched and fresh, and the age of the report
otherwise. The `modified` pill of ADR 0012 stays what it was — changed *during this session* —
while the counts are the whole working tree. The list of files is #14.

## Consequences

- `VibeDomain` gains `WorkingTreeStatus` and its parts; `VibeApplication` gains the ports
  `RepositoryStatusReading`, `FileChangeObserving`, `SessionTranscriptLocating` and the monitor.
  Neither knows `Process` nor FSEvents: `GitStatusReader` and `FSEventsFileChangeObserver` live in
  `VibeGit`, and `AgentTranscriptReader` says where its transcripts are.
- Nothing is persisted: the store keeps its schema.
- One transcript reader serves both the report and the monitor, so each file is read once,
  incrementally.
- A reading already under way when the application quits finishes on its own, within its 30 s:
  the runner cannot be interrupted. Once the monitor is stopped, nothing — a report read late on the
  way out included — opens a stream or starts a reading again.

## Out of scope

The list of files, their grouping and revealing one (#14); diffs; any network operation; watching
the sessions not on screen; attributing what the agent's shell commands wrote; any Git action —
staging, committing, removing a lock or repairing a moved repository is offered as a command to
copy, never run.
