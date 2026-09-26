# 0025 — Answering agents from the palette

- Status: accepted
- Date: 2026-09-26
- Issue: [#40](https://github.com/hadrienl/vibe-manager/issues/40)

## Context

An agent in a background session that stops for a permission, a question or a plan waits until
someone opens its session. #45 already knows it waits (ADR 0022): its hooks report the request,
and keep its payload. What was missing is the request itself — what it asks, whose it is — and a
way to answer it without leaving the session in front.

## Decisions

### Answering is typing into the session's terminal

The answer is written into the terminal of the request's own session, keystroke by keystroke,
exactly as the user would type it (`AnswerAgentRequest`). No hook decides, no API is called: what
the terminal shows stays true, and the answer reads in it afterwards. A `PermissionRequest` hook
that waited for Vibe Manager and answered in JSON was rejected: it would hold the agent — and the
dialog of the session in front — while it waits, turn the rule that a hook never decides upside
down, change Codex's approved hooks for every user, and cover neither questions nor plans.

The terminal is looked up by session when the keys are written, and written to directly, not
through its pane: the pane's keystrokes are read as the user's.

### A key is sent only once the dialog is drawn

Measured on Claude Code 2.1.282 in a pseudo-terminal: at `PreToolUse`, the dialog of
`AskUserQuestion` is not drawn yet — a digit sent then landed in the prompt, and the Return that
followed took the highlighted option, the wrong one. At `PermissionRequest` the dialog is drawn: a
digit sent within the millisecond answered it. Only `PermissionRequest` arms a request; one
announced by `PreToolUse` is shown, its buttons waiting.

Return never picks an option: a digit does. Refusing is Escape, whatever the options: the digit
of "No" guessed one place off would allow.

| CLI | Permission | Always | Refuse | Questions | Plan |
|---|---|---|---|---|---|
| Claude Code 2.1.282 | `1` | `2`, only with `permission_suggestions` | Escape | a digit per question; the one after the options, pasted text and Return; `1` submits several | `1` / `2`; Escape rejects |
| Codex 0.157.1 | `y` | `p` (a command prefix), `a` (a patch's files) | Escape | in the terminal | — |

Questions with several choices toggle, and are sent from a tab of their own: left to the terminal.

### A queue per session

Claude Code reports every pending permission as it is created — two sub-agents asking together
send two `PermissionRequest` before either is answered — and draws their dialogs one at a time, in
that order. Each session keeps a queue; only its first request is answered from outside.

`PermissionRequest` carries no call identifier. A request is known by the log line that carried it,
and a tool that finishes settles it only if it matches: same tool, same agent (`agent_id`), same
command, file or address. The hook of a finishing tool now keeps those fields
(`Payload.fields`), read from the first 16 KiB, where they sit before the tool's output. A tool that
settles the second request, or one that cannot be told apart, puts the first in doubt: until the
queue drains, the session is answered in its terminal. A sub-agent's dialog outlives the end of the
main turn, and the prompt a background task sends.

### What would be allowed is what is shown

A permission whose payload was cut at the hook's limit can only be refused from outside. Text an
agent wrote is shown with its control characters, escape sequences, direction changes and
invisible characters named (`DisplaySafeText`), never interpreted.

### Codex's questions come from its rollout

`request_user_input` has a `PreToolUse`, but a new Codex hook would have to be approved again by
every user. The rollout already says it — a `function_call` named `request_user_input`, then its
`function_call_output` — and reading it needs no approval. The rollout is the one created for the
working directory once the session started, as the identifier capture finds it. Nothing says when
the question is drawn, so it is shown and answered in the terminal.

### The palette, and what signals a request

The palette sits over the foot of the sidebar, in its column: it cannot cover the session in front,
whose own requests stay in its terminal. It lists every column's requests, oldest first, and folds
into a count (`WorkspaceLayout.isRequestPaletteCollapsed`). ⌥⌘P gives it the keyboard.

A request arriving while the application is in the background is notified. The notification says
the kind of request by default, the command or question if the user asks for it, and nothing on a
lock screen. A permission can be allowed or refused from it: Allow requires unlocking first, and is
offered only for a request armed and shown in full. The Dock counts every pending request.

## Consequences

- The keymaps are the CLIs' conventions, not an interface. Fixtures pin them; a CLI that changes a
  key makes the palette type a key its dialog ignores, or one it reads differently — which is why a
  refusal is Escape and no option is picked with Return.
- Two Codex sessions started in the same folder in the same seconds could show each other's
  question. It is only shown, never answered.
- A process of the same user that writes a false line into a log can make a false card appear
  (ADR 0022). Answering it types a digit or Escape into that session's terminal, nothing more.
