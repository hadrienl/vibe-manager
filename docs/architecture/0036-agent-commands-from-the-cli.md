# 0036 — The skills and commands under `/` come from the agent's CLI

- Status: accepted
- Date: 2026-09-30
- Issue: [#219](https://github.com/hadrienl/vibe-manager/issues/219)

## Context

Typing `/` first in the composer of the conversation view lists the skills and commands of the
session's agent. Each CLI finds them its own way, and those ways move fast: Claude Code reads user,
project and plugin skills, commands in `commands/`, skills synced from claude.ai (with aliases such as
`anthropic-skills:docs`), and has its own built-in commands. Codex reads user, repository, system and
admin skills, plugins, and invokes a skill with `$`, not `/`.

## Decision

### Ask the CLI, do not rediscover it

Each provider implements `AgentCommandListing` by asking its CLI, with the executable, environment
(`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) and folder of a launch plan for the session's folder:

- **Claude Code**: `claude -p --input-format stream-json --output-format stream-json --verbose
  --no-session-persistence --settings {"disableAllHooks":true} --strict-mcp-config`, then the
  `initialize` control request. Measured against 2.1.285, it answers in 1 s without calling the model.
  `--strict-mcp-config` keeps the user's MCP servers from starting: without it, each reading started
  three of them, for the same list. The answer lists each entry's
  name, description, argument hint, aliases, and whether it is built in. The user's hooks are turned
  off, because a `SessionStart` hook would believe a session started. No transcript is written. The
  answer does not say where an entry comes from, so the origin is worked out:
  - `builtin` marks a built-in command;
  - a `(user)` or `(project)` suffix marks a command of `commands/`;
  - a `plugin:` prefix marks a plugin;
  - otherwise the skill folders of the project and the user are checked.

  The commands whose result is drawn in the terminal alone (`/usage`, `/context`) are left out, and so
  are the commands the terminal UI keeps for itself, which the CLI does not list.
- **Codex**: `skills/list` of `codex app-server` (0.159.2, 0.3 s), through `CodexAppServerProcess`. It
  lists the skills with their scope and plugin, and the skills it could not read, which go to the
  diagnostics. A skill is inserted as `$name`. Codex lists no command, so two of its own commands whose
  effect shows in the conversation (`/compact`, `/init`) are named by the provider. Its
  `prompts/*.md` are read from disk, as `/prompts:<name>`, only when that folder exists.

A provider that implements nothing lists nothing, and `/` stays text.

### Read in the background, kept per agent and folder

`AgentCommandCatalog` keeps one list per agent and folder, shared by the sessions that run there. The
list is read when a conversation is first shown. Each time the list opens, the list kept is shown at
once and read again behind it if it is older than 30 s. A skill added on disk therefore shows the next
time the list opens, without FSEvents. A reading that fails keeps the list read before.

### Two places, one list

`ComposerCommands` holds the list's state for a text: the composer of a conversation and the initial
prompt of a new session each own one. The new session reads the list for the agent and folder chosen
in the draft, only once `/` is typed: typing a folder starts no CLI. Claude Code runs a command given
as its initial prompt (measured with `/context`).

### The state is read from the draft

As with the shell mode (#188), the list is open when the whole draft (blanks aside) is a trigger
followed by a name without a blank. Escape closes it for the command being typed. A message recalled
from the history does not open it. While the list is open, ↑, ↓, ⇥, ↩ and Escape are its own. ↩
inserts the selected entry and sends nothing. With nothing matching, ↩ sends the text as it is.

Search and order are pure (`AgentCommandIndex`), and the entries are folded once when the list is
read. The order within each group (skills first, then commands) is:
1. a name that starts with the text;
2. a part of a namespaced name that starts with it;
3. an alias that starts with it;
4. a name that contains it;
5. a description that contains it.

### Sending is unchanged

The text sent is the text shown. Measured: Claude Code runs a command that is typed to it, and Codex
runs one that is pasted. Claude Code writes a skill it ran as `<command-message>…<command-name>…`. The
decoder used to drop that as plumbing; it now reads it as a command, which also confirms the echo of
the prompt sent.

## Consequences

- The list follows each CLI's version without code here. The cost is a short process per reading, in
  the background.
- A CLI that stops answering (renamed option, changed protocol) leaves the list empty. It never breaks
  the composer, and the failure is in the diagnostics.
