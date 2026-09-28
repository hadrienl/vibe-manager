# 0005 — The Codex CLI provider

- Status: accepted
- Date: 2026-09-21
- Issue: [#5](https://github.com/hadrienl/vibe-manager/issues/5)

## Context

ADR 0003 made adding an agent a matter of declaring a specification and an argument builder.
ADR 0004 gave sessions a real pseudo terminal. Codex is the first concrete agent to use both,
and it is the one that tells whether that abstraction actually holds.

Two of its properties shape everything here: it is a full screen terminal interface, not a
batch command, and it identifies a conversation with a session identifier it does not
advertise in a stable way.

## Decisions

### The interactive interface, never `codex exec`

`codex exec` is the non interactive mode: no approvals, no way for the user to take over, no
terminal interface. The application drives the same `codex` a user runs by hand, in the
pseudo terminal ADR 0004 provides.

### The prompt is an argument, never the standard input

ADR 0003 moves a prompt above 16 KiB from `argv` to the standard input. That rule cannot apply
here: in a pseudo terminal the standard input *is* the keyboard, so writing a prompt there
types it into the composer and its first newline submits a half written message.
`CodexArgumentBuilder` therefore refuses a `.standardInput` delivery with
`promptTooLarge`, and the plan only ever carries `.argument` or `.none`.

### Every positional goes after `--`

A prompt starting with `-`, or a session named `--last`, would otherwise be parsed as an
option. `--` removes the whole class of problems, and arguments already travel as an array,
never as a shell string.

### The working directory is passed twice

The process starts in the session directory *and* receives `-C`. Codex derives its workspace
root and filters resumable sessions from that directory, and an explicit flag makes the plan
readable without knowing how the process was started.

### Model slugs are validated in shape, not in membership

`models()` reads the list Codex already cached in `$CODEX_HOME/models_cache.json` — no network
call, no process, and a silent fallback to "no choice offered" whenever that file is missing
or unreadable. Nothing is hard coded: model names change between two releases of the CLI, and
a stale list would offer models that no longer exist.

The launch validation only checks that a slug is a plausible token. Rejecting an unknown slug
would make Vibe Manager expire faster than the CLI it drives. An empty choice means "whatever
`config.toml` says", which is the user's own decision.

### Resume names its session, explicitly

`codex resume -- <SESSION_ID>`, with the identifier required. `--last` would resume the most
recent session on the machine, possibly one started by another tool, and the interactive
picker would leave the pane waiting on a selection nobody is there to make.

### The identifier comes from the rollout file, with the terminal as a bonus

Codex writes `rollout-<timestamp>-<uuid>.jsonl` under `$CODEX_HOME/sessions`, whose first line
carries `session_id` and `cwd`. `CodexRolloutSessionDiscovery` watches for a rollout created
after the launch whose `cwd` matches the session, which is the only source that does not
depend on how the interface renders. It keeps the *oldest* rollout created after the launch,
not the newest: a pane started a second later in the same repository would otherwise be
handed this pane's identifier, and both sessions would resume the same conversation.

Two rules keep that attribution honest in both directions. The creation date is compared
strictly against the launch, with no tolerance: a rollout older than the launch belongs to an
earlier pane, and admitting it would let the pane started *second* adopt the session of the
pane started first — the same confusion, mirrored. And `CodexSessionClaims` hands a session
out once per process: a rollout another pane already took is not ours, however well it
matches.

`CodexResumeIdentifierExtractor` also reads the terminal output, but only accepts a well
formed identifier on a line naming a session: the output echoes the prompt, and a prompt can
contain a UUID of its own. `CodexTerminalIdentifierAccumulator` holds the unterminated tail of
the stream, bounded, because a pseudo terminal read cuts wherever the kernel buffer ended. The
capture queues the reads and drains them one at a time, in the order they arrived: splicing a
tail onto the wrong half would lose the identifier for the whole launch.

`CodexSessionIdentifierCapture` races the two sources for one launch: the first to answer
wins and nothing overwrites it afterwards, so a false positive read from the screen cannot
replace what the rollout established, nor the other way round. A later launch of the same work
session does replace it — that is a new conversation. `RecordAgentResumeIdentifier` stores the
result through `SessionRepository.mutate`, after a read that keeps the steady state free of
writes, and answers with *why* it did or did not write. The capture only considers an
identifier acquired once that write landed: a rollout can appear before the creation flow has
attached the agent configuration, and a single dropped write would make the session
unresumable for good. A refusal that a later state could lift is retried within a bounded
window; one that no state can lift is reported as `unstoredIdentifier` rather than passed off
as a session that never revealed one. No transcript is persisted: ADR 0002 excludes them and this ADR does not widen it.

The capture object is built by the provider and handed the session, its directory and the
repository. Nothing starts an agent yet — the creation flow is #7 — so this ticket delivers
the mechanism and its seam, not a live wiring.

### The agent names its session itself, whenever it gets to it (#144)

Checked against `codex-cli 0.157.1`: Codex creates its session — identifier, `session_meta`
timestamp — when the process starts, but writes nothing that names it, not the rollout, not a row
of its state database, until the first message. The rollout and the `SessionStart` hook then
appear together, a fraction of a second apart, possibly hours after the launch. No option of the
CLI sets the identifier or the rollout path, and neither the environment nor the first line of
the rollout carries anything that ties it to one process (no pid).

The one report that cannot belong to another launch is the hook: `SessionStart` receives
`session_id` and `transcript_path`, and writes into the log of its own session (ADR 0022). Its
payload keeps `session_id`, and only it. `TrackAgentActivity` reads it like any other line, the
decoder recognises it (`conversationIdentifier(in:)`), and `SessionLauncher` hands it to the
observer of that session's process (`conversationNamed`), launched or adopted. The capture then
stores it, in place of whatever the rollout or the terminal suggested, and nothing else writes
after it; a later `SessionStart` of the same process replaces it in turn. A name the session could
not carry yet is handed to the next instance in `runtime.json`, as #141 does for Claude Code, and
an adopted process gets an observer even with nothing to take up, to hear the name when it comes.

The rollout discovery stays, as the net under hooks that do not run:

- With hooks known to run — approved in Vibe Manager, or already trusted by Codex — it looks for
  thirty seconds, as before.
- Otherwise it looks for as long as the process lives: the user declined the hooks, or they are
  passed but their approval is unknown or did not take, and Codex may still be told no in the
  terminal (`ReportedLaunch.hooksApproved`). Every half second during thirty seconds, then twice
  as slowly every thirty seconds up to one look every five seconds, with a limit of twelve hours.
- Whichever it was, one last look is made when the process ends, the watch over or not: a first
  message sent just before quitting may have left its hook unread.
- A resumed conversation (`codex resume`) does not look at all: its rollout already exists, and a
  new one in the same folder would be another launch's.

Matching a rollout found that late needs more than its creation date, which now says when the
user spoke. Its first line says when the session began, which is when its process started: a
rollout whose session began more than five seconds before the launch is an earlier pane's, however
late it was written. And every launch still waiting for its session is registered with its folder
in `CodexSessionClaims`, until it knows its session or ends. A waiting launch stands in the way of
a rollout only if the session began while it was starting — from five seconds before it to thirty
seconds after (`startWindow`) — and a rollout two waiting launches of the same folder could have
begun is handed to neither. A pane left silent for an hour therefore does not keep a pane launched
since from finding its own; two panes started within thirty seconds of each other in the same
folder record nothing from the disk until the doubt is lifted — the hook, or the other launch
ending. Nothing is recorded rather than a conversation that may be another pane's. A session named
by a hook or read from a terminal is claimed too, so that no discovery hands it out again, and a
rollout the hook proved to be another launch's is released for that launch to find.

### Nothing lowers the user's safety settings

Neither `--sandbox`, nor `--ask-for-approval`, nor `--dangerously-bypass-*`, nor `--worktree`,
nor `--search` is ever passed. The policy in `config.toml` is the user's, and lowering a guard
rail from a graphical interface would be a silent privilege escalation. Exposing those
settings is product work (#7, #15); worktrees are #12.

### Authentication is an exit code, secrets are never touched

`codex login status` is run with a timeout and only its exit code is read. No token,
`auth.json` or keychain item is ever opened, and no API key is injected into the agent
environment: `codex login` owns that. An unproven sign in state stays launchable, because the
CLI asks for itself, in the terminal, where the user can answer.

`CODEX_HOME` is forwarded when set, and the same value decides where the model cache and the
rollouts are read. A tilde prefixed value is expanded; one that cannot be resolved into an
absolute path is dropped from the agent environment instead of being passed on, so the CLI and
the discovery never disagree about where sessions live — forwarding it would produce a resume
that silently never works. Proxy and certificate variables are forwarded too, because a
corporate Mac without them fails with a network error whose cause is nowhere near its message.

### The minimum version is the one that was verified

Only `-m`, `-C/--cd` and `resume <SESSION_ID>` are used, and they were checked against
`codex-cli 0.153.2`. The declared minimum is that release series. Older ones very probably
work, but the application states what it verified rather than what it assumes: below the
floor, Codex is reported as outdated with an update remediation, not launched into a command
line nobody exercised.

## Consequences

- Adding Codex touched no view and no existing use case: a specification, an argument builder,
  a catalog, an identifier source, and one line in `AppEnvironment`.
- Model choice depends on a file written by the CLI; a machine where Codex has never run
  offers no model until it does, which is honest rather than wrong.
- A large prompt is refused instead of being half delivered, and the limit is visible.
- The resume identifier can be missed — a rollout written elsewhere, a session that never
  starts — and the session is then simply not resumable, which the diagnostic states.
- Polling the rollout directory is a compromise: it is bounded in time and reads only the
  first line of candidate files, but it is polling, not an event stream.
- Without hooks, two Codex panes started within thirty seconds of each other in the same folder
  record nothing until one of them ends; and a Codex started outside the application, in the
  same folder, while a pane waits, can still be taken for that pane's. With hooks, the discovery
  only runs thirty seconds, and the hook of the first message replaces whatever it found.
- A session begun more than thirty seconds after its launch — a new conversation started in a
  pane before its first message, a folder-trust screen left open — is not seen as that launch's:
  a pane launched later in the same folder may take it — with hooks, only within its own first
  thirty seconds, and until its own hook names its session.
- A process adopted from a version that did not keep `session_id` in its `SessionStart` hook is
  never named: its hooks are the ones it was started with.
- Keeping `session_id` changed the command of the `SessionStart` hook: every user approves the
  Codex hooks once more (ADR 0022).

## Rejected alternatives

- `codex exec` with a JSON stream was rejected: it gives a machine readable session identifier
  but removes the interactive session that is the point of the product.
- Parsing the terminal output as the only identifier source was rejected: the interface layout
  is not a contract.
- Reading `~/.codex/auth.json` to know whether the user is signed in was rejected: the
  application has no business touching credentials, and an exit code answers the question.
- Hard coding a model list was rejected: it would be wrong within weeks.
- `codex resume --last` was rejected: it resumes whatever ran last on the machine.
