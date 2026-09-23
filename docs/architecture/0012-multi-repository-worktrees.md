# 0012 — Several repositories, and coordinated worktrees, per session

- Status: accepted
- Date: 2026-09-23
- Issue: [#12](https://github.com/hadrienl/vibe-manager/issues/12)

## Context

A task rarely stays inside one repository: the API, the front end and the shared package move
together, and the same branch is wanted in all three. Until now a session carried a single folder
(#7), stored as a `RepositoryContext` with no branch and no worktree, and `VibeGit` could do nothing
(`EmptyGitWorkspaceService`).

This ticket makes the session the carrier of one convention — **one slug, one branch, one worktree
per repository** — and makes the operation visible before it runs, repairable repository by
repository when it stumbles, and never destructive.

## Decisions

### The session is a branch, and it is the same everywhere

The slug is computed once, when the session is created, from its title: NFKD decomposition,
transliteration to ASCII, lower case, every run of anything outside `[a-z0-9]` turned into one
dash, cut at 40 characters on a word boundary. A title that leaves nothing falls back to
`session-<6 hex>`, drawn once per draft so the preview does not move at every keystroke.

It is stored on the session (`WorkSession.slug`) and **never recomputed**. Renaming a session is
frequent and cosmetic; its branch may already be pushed, known to the CI and to a colleague. The
sheet shows it in a field of its own that follows the name *until the user types in it*, and that
refuses, in the field, what `git check-ref-format --branch` would refuse — plus a leading dot or
dash, `.lock`, a slash (it is also a folder name) and the empty string.

The branch is `vibe/<slug>`, fixed in V1. The prefix makes the application's branches recognisable
at a glance and removable in one pass by their owner; making it configurable is a preference, and
preferences are designed together.

Uniqueness is checked against the slugs of the sessions that are not archived, and against the
branches of the repositories being attached. The next free suffix (`-2`, `-3`…) is **proposed,
never imposed**: reusing an existing branch is sometimes exactly the right gesture — a session
picked up again — and the plan offers it as such.

The slug only matters once it names a branch. A session whose folders are all plain or worked
in place stores none, is never refused over its title, and its sheet does not show the field: two
sessions called "Review" on two folders share nothing.

A session stored before this ticket has no slug. It is given one from its name the first time a
worktree is attached to it, and keeps it from then on.

### Where worktrees go

```
~/VibeManager/Worktrees/<slug>/
  ├── api/          worktree of ~/code/api
  └── legacy-api/   worktree of ~/legacy/api
```

One root, changeable in Settings through the open panel. Not inside the repository — a nested
worktree shows up in its `git status`, in the agent's searches and in its builds — and not beside
it either: writing in the parent of a designated folder is an access macOS never granted (ADR
0010). One root is one permission, asked once.

The folder of a repository is the last component of its clone's path; two of the same name in one
session get the parent component in front (`api`, `legacy-api`), then a counter. A bare counter
(`api-2`) would not say which is which.

No command is ever built as shell text: `git` is run with an array of arguments, so a folder called
`Mes Projets/l'API (v2)` needs no quoting. The only place a path becomes text again is the cleanup
command offered to the user, which is quoted for the shell.

### What an attached repository is

`RepositoryContext` gains what tells the clone from the place the work happens: `rootPath` (the
clone, never moved), `mode` (`worktree`, `inPlace`, `plainFolder`), `worktreePath`, `branchName`,
`baseRevision`, `createdByVibeManager`, `attachedAt`, and a `failure` — a sentence and a remedy —
for a repository that could not be prepared. `GitSnapshot` stays what it was, a dated photograph:
no live Git state is stored (that is #13 and #14).

- **Three modes, not two.** A folder of notes or data is not a mistake; it takes part in the
  session with no branch and no convention.
- **The first repository is the main one.** It decides where the agent starts. Sessions are still
  grouped by `rootPath`, never by the worktree, so a session working in a worktree stays filed
  with its project.
- **`createdByVibeManager` is stored**, so an adopted worktree is never presented as the
  application's own — least of all in the cleanup command.

`sessions.json` moves to **schema v3**. The v2 → v3 migration turns `path` into `rootPath` and every
repository into `inPlace` — exactly what those sessions were doing — with everything else empty. No
migration looks at the disk or creates a worktree. A v3 document with a slug Git would refuse is a
corrupted store, handled as every corrupted store is (typed error, backup untouched).

### Read, plan, then act

```
designated folder
      │
      ▼
RepositoryInspecting        read only: rev-parse, symbolic-ref, worktree list --porcelain -z,
      │                     for-each-ref, status --porcelain=v2 -z
      ▼
SessionWorkspacePlanner     pure: slug + facts ──▶ plan per repository, with its conflicts
      │                     (recomputed on every keystroke of the slug, reads nothing)
      ▼
 the user reads, fixes, confirms
      │
      ▼
PrepareSessionWorkspace     a queue of independent repositories, each alone
      │                     git worktree add …  ──▶  RepositoryContext
      ▼
CreateSession / AttachRepository  ──▶  store  ──▶  launch
```

- **`git` is a port.** `GitCommandRunner` lives in `VibeApplication` and takes an executable's
  arguments and a folder; `ProcessGitCommandRunner` in `VibeGit` runs it. Everything that plans is
  tested without a repository, and the integration tests create real ones.
- **Plumbing only**, whose output is stable between versions and parses without heuristics. `-z`
  wherever Git offers it, because a file name may contain a newline. Reads run with
  `GIT_OPTIONAL_LOCKS=0`, so inspecting a repository an agent is committing in never collides with
  it; `GIT_TERMINAL_PROMPT=0`, so nothing ever waits for a password.
- **`git` missing, or the Xcode stub.** On a new Mac `/usr/bin/git` exists and only offers to
  install the Command Line Tools. It is recognised by asking `xcode-select -p` before it is run,
  and reported as a typed diagnostic with its remedy (`xcode-select --install`). A folder without a
  `.git` is then still attachable as a plain folder.
- **Concurrent writes.** One queue per `git-common-dir` (`GitWriteSerializer`) serialises the
  commands that write. Two sessions created at the same moment on one repository would otherwise
  meet on `index.lock`, and that error teaches nobody anything. The branch is checked again under
  the lock (`show-ref --verify`) before `worktree add`.
- **Partial failure keeps what worked.** Destroying what succeeded to "undo cleanly" contradicts
  the rule below and costs the user work they did not ask to lose. The failing repository is
  attached with its failure.
- **Idempotence.** A repository of the session prepared again — a restart, a repair — *adopts*
  the worktree it finds at its own path: "nothing to do". At **creation**, the same finding is a
  conflict with "work in that worktree" offered: the worktree may be what an archived session of
  the same name left, and working in it silently would put the new session on top of the old one's
  work. A crash between preparation and storage therefore costs one click, never a duplicate.
- **What was shown is what runs.** Create is disabled until every repository's plan is on screen.
  At creation every folder is read again, and a plan that would now do something else is not
  carried out: the sheet reads the folders again and asks the user to look once more.
- **The base** is the clone's `HEAD`, shown in the plan; a selector per repository starts from the
  default branch (`origin/HEAD`) instead — the mainline, which a coordinated change across three
  repositories often wants.
- **The session folder** is created at the first preparation and never removed. It is read back
  from the session's own worktrees afterwards, not recomputed from the root: after the setting
  changes, `VIBE_SESSION_ROOT`, a repository attached later and a repair all stay in the folder the
  session already has. It is also where
  the Finder is sent when the user wants to see what was made.
- **The main repository decides whether the session can be created.** A conflict holds back only
  the repository it is about — except for the main one, where there would be nowhere to start the
  agent. That one conflict holds back the whole form, with "move another repository first" among
  its remedies. A main repository that fails *during* preparation leaves a stored session that is
  not started, and says why.

### Vibe Manager creates, and never deletes

No code path calls `git worktree remove`, `git branch -d`, `git worktree prune` or `rm`. The port
that writes (`WorktreeCreating`) has no method that could. Detaching a repository, closing,
archiving, or failing a preparation all *forget*, and leave the work where it is. What the
application offers instead is the command to copy — `git -C <clone> worktree remove <path> &&
git -C <clone> branch -d <branch>`, quoted, prefixed with a warning when the worktree was adopted —
and the user stays the only one to decide on a loss. A test runs every one of those paths through a
runner that fails on any of those commands.

### Conflicts, and what is proposed

Each conflict blocks **its repository**, comes with a sentence, a remedy, a command to copy when
there is one, and gestures that are proposed and never applied on their own
(`RepositoryAttachmentIssue`, rendered with the same view in the sheet, the attach sheet and the
inspector).

| Found | What happens | Proposed |
|---|---|---|
| Not a Git repository | attached as `plainFolder` | keep it as it is; choose another folder |
| `vibe/<slug>` exists, checked out nowhere | blocked | put the worktree on it (no `-b`); change the slug |
| `vibe/<slug>` checked out in a worktree | blocked — Git allows one worktree per branch | work in that worktree; change the slug |
| The worktree path exists and is not a worktree of this repository | blocked | change the slug; another folder name |
| A stale worktree record | blocked | `git worktree prune`, to copy — never run |
| A locked worktree | blocked | the lock's reason and `git worktree unlock` |
| Uncommitted changes | nothing in worktree mode (a notice); a warning in place | use a worktree |
| Detached `HEAD` | nothing in worktree mode; blocks in place, which has no branch to name | create the session branch there; use a worktree |
| Bare repository | blocked | choose a working clone |
| The same repository twice (same common dir, through a worktree or a link) | blocked | remove it — nothing is merged silently |
| Submodules | a warning | the command that initialises them |
| Folder missing, unreadable, not a folder | blocked | the existing `SessionDraftIssue` sentences |

### Where the agent works

- **Working directory**: the main repository's effective path — its worktree if it has one, its
  clone otherwise. The session folder is not used: a repository attached in place lives elsewhere,
  and the agent would start in a folder that holds only part of the work.
- **The other repositories** go to the provider as `AgentLaunchRequest.additionalWorkingDirectoryPaths`,
  which both CLIs translate to `--add-dir` (checked on `claude` 2.1 and `codex-cli` 0.155, including
  `codex resume`). A provider that cannot take them says so through
  `AgentCapabilities.supportsAdditionalDirectories`, leaves them out rather than pretending, and
  the sheet says only the main repository is reachable.
- **Environment**: `VIBE_SESSION_SLUG`, `VIBE_SESSION_BRANCH`, `VIBE_SESSION_ROOT` — free, and what
  the user's scripts and hooks read to name a merge request or a build folder.

### The convention is in the prompt, and shown before it is sent

`SessionConventionBuilder` is pure — a session in, a text out — and its block opens the first
prompt, identical for both providers. Not `--append-system-prompt`, which only Claude Code has: two
texts would be two behaviours to test, and a system prompt is something the user cannot read
before it is sent in their name. The block is shown, folded, in the sheet before creation.

- A session **with no initial prompt** gets the block alone, closed by "Do not start working yet:
  wait for my next instruction." A convention has to arrive before the first file is touched; the
  closing sentence is what stops an agent from inventing a task.
- A session with **one repository in place** gets no block: nothing to coordinate, and #7's
  behaviour is unchanged.
- **Budget.** The block counts within the 16 KiB of `argv`. When the whole does not fit, the list
  of repositories is summarised first; the user's prompt is theirs, the convention is plumbing.
- **Restart (#10).** `SessionContextBriefBuilder` gains a `convention` section right after
  `heading`, never dropped — it may be summarised. An agent restarted without its conversation must
  learn the convention before anything else: it is the one thing it cannot deduce from the files.

### Adding and removing afterwards

- **Adding**, from the inspector, goes through the same road: read, plan, confirm, prepare.
- **Adding** a repository whose plan is held back is not possible: resolving the conflict is right
  there, and a line that cannot be prepared helps nobody once the session exists.
- **Adding to a running session** prepares the worktree, then *proposes* an addendum for the
  terminal, with its text visible. Nothing is typed without a click: writing into a pseudo terminal
  is typing on the user's keyboard, and the first newline submits a message — the same refusal as
  #11. The click sends it as a bracketed paste followed by Return, so the composer takes it whole. The
running process was not started with the new folder among its `--add-dir`, and the addendum says
so rather than letting the agent discover it through a refusal; the next restart hands it over.
- **Detaching** forgets, and that is all: the worktree and the branch stay. The notice offers the
  cleanup command to copy; the row offers Reveal in Finder.
- **Detaching the main repository** makes the next one main; a running agent is **not** restarted,
  and the notice says so — a process's working directory cannot be moved, and pretending would be
  worse than saying it.
- **Closing, archiving** have no effect on disk. (No session is ever deleted, per ADR 0009.)

### The branch report: what the agent did, found rather than named

The convention tells the agent where to work; it does not say what the agent did. An agent cuts
its own branches, moves others forward, switches mid-way — and the user wants to *find that out*,
repository by repository, without having named anything beforehand.

- **The reference is a photograph** (`GitReferenceSnapshot`, stored as `RepositoryContext.baseline`):
  every local branch with its commit, the branch checked out and `HEAD`, taken on the one road to a
  process (`SessionLauncher`) the first time an agent runs for the session — or when a repository
  is attached while it runs. It is never retaken on a restart: the report is about the session's
  life, and a restarted agent does not reset it to nothing.
- **What is said**: branches created (with their own commits — those neither the start nor any
  other branch has now), moved forward (+N commits), rewritten (the old commit is no longer in their
  history), deleted; the branch checked out now; uncommitted changes. The age of the reading is
  written next to it.
- **Rhythm**: every 30 seconds for **the session on screen only**, while its agent runs; once when
  it is selected, and once when its agent stops. Twenty sessions read continuously would cost the
  disk for columns nobody looks at.
- **Read only**, with `for-each-ref`, `symbolic-ref`, `rev-parse`, `rev-list --count`,
  `merge-base --is-ancestor` and `status`, under `GIT_OPTIONAL_LOCKS=0`: reading every 30 seconds
  a repository an agent commits in must never take its `index.lock`.
- **A repository worked in place** has its current branch recorded at every launch, so the
  inspector says which branch it is on — a session migrated from v2 had none.
- **Where the session worked comes from its own transcript**, not from the repositories: a reflog
  says what moved, never who moved it, and two sessions in one folder were told each other's work.
  Claude Code's transcript (and each sub-agent's, under `<id>/subagents/`) gives the `cwd` of every
  line and the `file_path` of every edit; a Codex rollout gives its `cwd`, the `workdir` of its
  commands and the files its patches touch. Each path is brought back to the worktree it belongs
  to — hidden ones included, since an agent that makes itself a worktree under
  `.claude/worktrees` works there, not in the clone. Transcripts are read incrementally, from where
  the last reading stopped.
- **For each of those repositories**: the branch checked out, what its reflog says that branch did
  since the session started (created, +N commits, rewritten), and uncommitted files written since.
  Only that branch — the others may be moved by anyone. A repository the agent only passed through
  is named, not detailed. With no transcript to be found, only the attached repositories are
  known, and the inspector says so. A clone attached in place and shared by several sessions still
  shows the same branch to each: that is what worktrees are for.
- **One "Git" section** in the inspector, not a list of folders and a list of branches: each
  attached folder with the branch it is on and what moved, and under a folder of repositories the
  ones the session touched, each with its own branch. Attaching another repository sits in the
  section's menu.
- **Out of scope**: repositories outside the attached folders, file lists and remotes (#13, #14).

### Restart and restoration verify first

Restart (#10) and restoration (#11) read every repository again before launching
(`VerifySessionWorkspace`):

| Found at restart | What happens |
|---|---|
| Worktree there, on the right branch | nothing |
| Worktree there, on **another** branch | the session starts as it is, with a warning naming the branch — it may be deliberate |
| Worktree gone, main repository | the launch is refused; "recreate the worktree" is the remedy, a gesture and not a side effect |
| Worktree gone, secondary repository | the session starts without it; it stays attached, the warning says it is missing, and the convention tells the agent not to work there |
| Clone moved or gone | marked missing; nothing is repaired automatically |

"Recreate the worktree" (`RepairRepository`) plans that one repository again on the branch it
already has, in the folder it had, and meets any stale record with the same copyable command as at
creation. A repair that fails changes only the reason recorded: the worktree's path, its base and
whose it was stay, since the inspector and the cleanup command need them.

## Consequences

- `VibeDomain` and `VibeApplication` still know nothing of SwiftUI, AppKit, SwiftTerm or `Process`:
  Git is reached only through `GitCommandRunner`, `RepositoryInspecting` and `WorktreeCreating`.
  `EmptyGitWorkspaceService` is gone.
- `SessionCreation.plan` is optional: a main repository that fails during preparation leaves a
  stored session with nothing started, and `launchRefusal` says why.
- A workspace assembled without the Git services (tests, previews) attaches every folder in place,
  exactly as before; the sheet then neither reads nor plans anything extra.
- The app target links `VibeGit`, and the settings window gains the worktree root.

## Out of scope

Assisted cleanup (deleting a branch and a worktree from the application, even confirmed): V1 offers
the command, a dedicated ticket designs the gesture and its safeguards. Live Git state — changed
files, ahead/behind, reacting to external changes — is #13, and its display #14. Network operations
(`fetch`, `pull`, `push`, merge requests): nothing here talks to the network, so nothing waits or
fails because of it. Initialising submodules automatically: found and said, never run. A
configurable branch pattern and per-project naming templates. One agent per repository: a session
stays one agent with several folders. Synchronising the repositories (coordinated commits, grouped
rebases): the convention is a naming, not an orchestrator.
