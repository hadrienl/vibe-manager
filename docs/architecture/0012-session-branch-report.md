# 0012 — What the agent did to the branches, session by session

- Status: accepted
- Date: 2026-09-23
- Issue: [#12](https://github.com/hadrienl/vibe-manager/issues/12)

## Context

An agent working on a task makes its own branches, and sometimes its own worktrees (Claude Code
puts them under `.claude/worktrees`). A session could say which folder it was opened on, never what
happened there: which branch the work is on, whether it was created, how far it moved, whether
something is left uncommitted.

A first version of this ticket had the application create a branch and a worktree per repository
for every session, from a slug derived from its title. That was not the request: **the application
creates nothing in Git**. The agent decides whether it needs a branch or a worktree; the
application reports what it did.

## Decisions

### Where the session worked comes from its own transcript

A reflog says what moved, never who moved it: read from the repositories alone, two sessions in one
folder would be told each other's work. So the repositories come from the session's transcript:

- **Claude Code**: `~/.claude/projects/*/<id>.jsonl` and each sub-agent's under
  `<id>/subagents/` — the `cwd` of every line and the `file_path` of every edit.
- **Codex**: the rollouts named after the session under `~/.codex/sessions/YYYY/MM/DD/` — the
  `cwd`, the `workdir` of its commands and the files its patches touch.

Each path is brought back to the repository it belongs to with `rev-parse --show-toplevel`, so a
worktree the agent made for itself is a repository of its own, named after its clone
("Mobile · worktree 230-send"). Transcripts are read incrementally, from where the last reading
stopped.

The folder the session was opened on is listed too when it is in a repository, so the report is not
empty before the agent has written anything. A folder of repositories is not one; what the agent
went into is said by the transcript.

### What is said of each repository

- The branch checked out, and what its reflog says that branch did since the session started:
  **created**, **moved forward** (+N) or **rewritten** (rebase, reset). Only that branch: the
  others may be moved by anyone.
- Whether files changed since the session started are left uncommitted.
- A repository the agent only went into, and where nothing moved, is named ("Also looked in"), not
  detailed.
- With no transcript to be found, only the folder of the session is known, and the inspector says
  so.

### When, and how, it is read

- **Only the session on screen**, when it is selected, and then again each time its transcript
  grows or one of its branches moves, and once when its agent stops. Twenty sessions read
  continuously would cost the disk for columns nobody looks at. The first version read it every
  30 seconds while the agent ran; #13 replaced that timer with the file system's events (ADR 0013).
- **Read only**, with `symbolic-ref`, `rev-parse`, `reflog` and `status`, under
  `GIT_OPTIONAL_LOCKS=0`: reading again and again a repository an agent commits in must never take
  its `index.lock`. A branch whose reflog file was not written since the session started is not
  read at all.
- The report carries the time it was read, and the inspector says it ("read 20 s ago") rather than
  pass it off as live.

### Presentation

One "Git" section in the inspector, organised by **branch**: each branch the session worked on is a
heading, and the repositories it is checked out in are listed under it, with their pills (`new`,
`+N`, `modified`, `rewritten`).

## Consequences

- `VibeDomain` and `VibeApplication` still know nothing of `Process`: Git is reached through
  `GitCommandRunner` and `RepositoryActivityReading`, transcripts through
  `SessionTranscriptReading`. `EmptyGitWorkspaceService`, which did nothing, is gone.
- Nothing is persisted: the store keeps its schema, and the report is recomputed on demand.
- A workspace assembled without a branch reader (tests, previews) shows no report at all.
- `VIBE_DATA_DIRECTORY` launches an isolated copy of the application (its own store, runtime
  document and window layout), to watch a build without touching the one being worked in.

## Out of scope

Creating, deleting or repairing branches and worktrees: the agent's job, not the application's.
Live Git state — changed files, ahead/behind — is #13, and its display #14. Nothing here talks to
the network.
