# 0023 — The journal of a session: a summary by its agent, the resources it used

- Status: accepted
- Date: 2026-09-25
- Issue: [#36](https://github.com/hadrienl/vibe-manager/issues/36)

## Context

A session that has run for an afternoon holds, somewhere in its terminal, the merge request it
reviewed, the branch it made, the pull request it opened. Finding them again means scrolling. The
agents' transcripts already say all of it: the prompts, every tool call — `Bash` and `exec_command`
lines, `WebFetch` URLs, MCP arguments — what the agent answered, and where each turn ended
(`system/turn_duration` or `stop_reason: end_turn` for Claude Code, `event_msg/task_complete` for
Codex). `AgentTranscriptReader` (#13) reads them for Git; the branch report (ADR 0012) knows the
repositories; the notes (ADR 0016) showed how to keep a per-session file apart from the store.

## Decisions

### What can be extracted is never generated

The resources come from a deterministic, tested reading of the transcript — `ResourceRecognizer`,
pure functions with a table of cases each. A model only writes the summary's sentences.

| Read | For |
|---|---|
| Prompts, the agent's text, the strings of a tool's input (not what `Edit`/`Write` write) | URLs of issues, pull and merge requests |
| Command lines, cut like a shell would (`ShellWords`), here-document bodies removed | `gh`/`glab` with a number (`-R`, or the folder's remote), `git checkout -b`, `switch`, `branch`, `push`, `commit`, `worktree add`, `cd` and `git -C` |
| Outputs, only of `gh … create`, `glab … create`, `gh pr checkout`, `gh pr view` without a number | The URL a creation prints |
| Working folders under `.claude/worktrees/`, `.codex/worktrees/`, `.worktrees/` | Worktrees |

A word holding a variable or a substitution is unknown and never guessed. A number whose repository
cannot be known is dropped.

Identity is a canonical key, never a raw URL: `github:<host>/<owner>/<repo>#<n>` for both issues
and pull requests (GitHub numbers them together; the pull request wins when both are seen),
`gitlab:<host>/<path>#issue/<n>` or `#mr/<n>`, `branch:<git-common-dir>/<name>` (the same from the
clone and every worktree, `origin/x` is `x`), `worktree:<canonical path>`. A number handed to `gh`
is resolved into a URL and read by the same recognizer, so it shares the URL's key. Involvement
(`viewed`, `changed`, `created`) only rises. Order is first appearance; 1,000 resources at most,
the rest counted.

Nothing is asked of GitHub or GitLab: no title, no state. Git is asked only
`rev-parse --show-toplevel --git-common-dir` and `remote get-url` (`upstream`, then `origin`),
once per folder per run.

### The summary: a one-off call of the same CLI, never the conversation

Nothing is typed into the agent's terminal and nothing is added to its conversation: a prompt would
interrupt its work, cost a turn and pollute its context. `SessionSummarizingProviding` gives each
provider that can a `CommandLineSummarizer`, which runs the session's CLI — the executable and
environment of its own launch plan, so the same account — through `BoundedProcess`, from an empty
temporary folder (no `CLAUDE.md`, no `AGENTS.md`), the digest on its standard input, 90 s at most.

| Agent | Command |
|---|---|
| Claude Code | `claude -p --model haiku --tools "" --strict-mcp-config --no-session-persistence --setting-sources "" --settings '{"disableAllHooks":true}' --system-prompt … --output-format json --json-schema …`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`; the answer is `structured_output` |
| Codex | `codex exec --ephemeral --skip-git-repo-check -s read-only --disable hooks --disable apps --disable plugins -c mcp_servers={} -c tools.web_search=false [-m <…mini…>] --output-schema <file> -o <file> -`; the instructions lead the input |

No MCP server, no hook, no plugin, no transcript left behind that our own watches would take for a
session: the digest carries text from the web and from tickets, and nothing it says must reach a
tool that can act. Claude Code gets no tool at all; Codex cannot drop its shell, which runs in the
read-only sandbox, without the network.
`--bare` is not used: it ignores OAuth, so subscription accounts. Measured on the maintainer's Mac:
7–8 s and about $0.005 for Claude Code with Haiku, 11–15 s for Codex.

The digest (`TurnDigest`) is built without a model from the turns since the last pass: prompts
(1,000 characters), one line per tool call (200), the agent's last words per turn (1,500), the
resources seen since, the last ten entries. 16 KiB at most, the middle actions of the busiest turns
replaced by their count first; turns are shortened, never dropped, since entries are dated by their
number. Never the transcript, never a tool's output.

The answer is 1 to 5 entries `{text, turn}`. An answer out of the schema, empty, or with an entry
over 200 characters is a failed pass: nothing is added. An error that names an unknown option says
the CLI is too old, one that mentions logging in says it is signed out: the summary is then
`unavailable` until the next launch or a change of agent, and the pane says why.

### When: at the end of turns, for every active session

`SessionJournalMonitor` follows every active session, not only the one on screen: a session in the
background must summarize itself. One FSEvents watch of the Claude Code projects folder and of the
Codex sessions folder; an event wakes a comparison of names with the conversations followed, and
only files that grew are read, from their cursor.

- Resources are recorded as soon as a line names them, during the turn.
- A pass starts 10 s after a turn ended (a turn followed by another is one pass), at most once every
  5 minutes per session, one at a time per session, two at a time in the application.
- A failed pass is tried again after 1, 5 and 15 minutes, then at the next turn. Retry, in the
  pane, tries at once — also when the agent was found unable to, once it has been signed in.
- A session that stops being active is read and summarized a last time, its unfinished turn
  included, without waiting for the interval.
- Quitting cancels passes (their process group is killed); the turns they covered wait for the next
  launch. After a relaunch or a reattachment (ADR 0017), what the agent did meanwhile is read at
  once and summarized in one pass.
- The summary can be turned off in a Settings tab of its own, Activity; the resources are read anyway.

### A file per session, only appended to

`Journal/<session-uuid>.json` next to the notes, behind `SessionJournalStore`, implemented by
`FileSessionJournalStore` under ADR 0016's rules: temporary file, `fsync`, move; `0600`, folder
`0700`; a file that cannot be read is never written over. It stays under 4 MiB: at most 20 pending turns of 5 prompts and 60 actions, 500 entries,
1,000 resources. It holds the entries, the resources,
the transcript cursors (offset and inode: a replaced file is read again from its start, which the
keys make harmless) and the turns not summarized yet.

This departs from the design on the issue, which kept a second cursor per file for the summary: the
pending turns are kept condensed in the journal instead, so a pass that failed can be retried after
a relaunch even once Claude Code has cleaned its transcripts away (`cleanupPeriodDays`). Entries
are only appended; past 500, the oldest fold into one that says how many. A session archived keeps
its file; restoration, restart and history have nothing to do.

### An Activity pane, beside Git

The top pane of the inspector (ADR 0014) gets a segmented control, Activity | Git, the choice kept
in `WorkspaceLayout.inspectorTopTab` (Activity by default). The notes stay below.

Activity is one list, so that the arrows, Return and ⌘C work across it: the summary (the latest 30
entries, "Show Earlier" above them, a day heading when they span several), then the resources
grouped as Issues, Pull & Merge Requests, Branches, Worktrees. Links are found by `NSDataDetector`,
opened only when `http` or `https` — the text is written by a model — and a link to a known
resource shows its short name (`!1315`). Each resource says its involvement in words. Return opens
the page, the branch on its forge (or its repository in the Finder), the worktree in the Finder (its
closest existing parent, said so, when it is gone). VoiceOver reads each entry and resource as one
element, with an action per link.

The states of the summary are sentences, never an empty block: waiting for the first turn,
summarizing (after 300 ms), unavailable and why, failed with Retry, turned off with a way to the
Settings, and no journal for a session older than this feature.

## Consequences

- A summary costs the user's own account a small, bounded amount: one light-model call per session
  every five minutes at most, 16 KiB in.
- The resource list is only as complete as the transcript: a reference given to an MCP tool without
  a URL (`issues.get` with a project and an `iid`) is not listed, since its host is unknown.
- #45 could read turn ends from the same reader.

## Out of scope

- Titles and states of issues and requests, which would need the forges' network and credentials.
- A per-setting choice of model for the summary.
