# 0034 — Sub-agents in the conversation view

- Status: accepted
- Date: 2026-09-29
- Issue: [#180](https://github.com/hadrienl/vibe-manager/issues/180)
- Amends: [0025](0025-conversation-view.md), whose sub-agent was a tool call like any other

## Context

The conversation view (#38, ADR 0025) showed a sub-agent as an ordinary tool block, "Sub-agent:
<description>", with its answer as raw output. Its own transcript was located but never read, and
while it ran it was tied to nothing. Since Claude Code 2.1.28x almost every `Agent` call returns at
once and the sub-agent works in the background: the block said "succeeded" with the CLI's internal
"Async agent launched…" as its output, while the sub-agent was only starting.

#180 asks for a block of its own — type, description, state, mission, activity, answer — updated
while the sub-agent runs, sub-agents started together grouped, nested ones shown, Codex included,
and a conversation of many finished sub-agents opened without reading their transcripts.

## What the transcripts say (measured)

On 683 Claude Code sub-agents (2.1.284–2.1.285) and 23 Codex activities (0.157.1) of one Mac:

- **Claude Code** writes, beside `<session>.jsonl`, `<session>/subagents/agent-<id>.jsonl` and,
  from the moment the sub-agent starts, `agent-<id>.meta.json` with `agentType`, `description`,
  `toolUseId` (621 of 683: the others are skills run apart, started by `Skill`), `spawnDepth`
  (1 to 3) and `stoppedByUser`. Nested sub-agents are written in the same folder.
- 583 of 591 `Agent` calls returned `toolUseResult.status: "async_launched"` with the `agentId`;
  the others were refusals or errors. A skill run apart returns `status: "forked"`.
- The end is a `<task-notification>` — `tool-use-id`, `status` (`completed`, `failed`, `killed`,
  `stopped`), `summary`, `result`, `usage` — written as a user message or as a `queued_command`
  attachment, and written again each time the sub-agent is given more work.
- The answer is the notification's `result`, or a hand-back: a meta user line whose `origin`
  holds `handback: true`, `from: <agentId>` and the report, indented by two spaces after
  "The report follows:".
- **Codex** writes `SubAgentActivity` items — `started`, `interacted`, `completed` — naming the
  sub-agent's thread. The sub-agent's own rollout, `rollout-…-<thread>.jsonl`, is a fork: it first
  copies its parent's whole history, those turns keeping their own `started_at`, then writes its
  own turns. The task given by `spawn_agent` is encrypted.

## Decisions

1. **A sub-agent is a call of the main conversation.** Its state, its answer and what it used
   come from the main transcript: result, notification, hand-back. Its own transcript only adds
   its activity. `ToolCall.subagent: SubagentRun` replaces `subTranscript`; the state stays the
   call's, so that severity, grouping and the banner keep working. A call launched in the
   background stays `running` until its notification; stopping the turn does not end it.
2. **Tied by identifier, never by guessing silently** (`SubagentLinker`): the call a transcript's
   record names, then the sub-agent's identifier once the call returned it, then — for a
   transcript that names no call — the same prompt word for word, in the order they started.
   Without any of these, no link: the next look may find one. Never "the newest file".
3. **Read lazily.** `FollowConversation` reads a sub-agent's transcript while it runs, or while
   the user has its activity unfolded (`setUnfoldedSubagents`). A sub-agent that ends folded is
   read once more to its end, then left. A conversation of fifty finished sub-agents opens none of
   their files: its blocks show what the main transcript says.
4. **The same decoder, the same views, the same settings.** A sub-agent's transcript is decoded by
   its provider's decoder in a sub-agent mode — its mission and its hand-back are left to its
   block, Codex's copied history is left out — and its activity is laid out by
   `ConversationGrouping` and `BlockView`, with the settings of the view.
5. **Sub-agents started together are grouped**, whatever the grouping setting, as consecutive
   sub-agent calls with nothing said between them. Nesting is shown down to depth 3; deeper, the
   header and the answer only.
6. **A bar over the composer** lists the sub-agents running, at any depth: a background sub-agent
   runs long after its block has scrolled up. A pill brings its block into view and unfolds it;
   a sub-agent that ends stays four seconds, dimmed. The activity line stays: it carries Stop.
7. **Nothing is made up.** A sub-agent whose end never came, in a session whose agent no longer
   runs, is shown stopped without an answer. A Codex mission that cannot be read says so. The
   answer of a Codex sub-agent, written in its rollout only, is read when its block is unfolded.
8. **A permission a sub-agent asks for is attributed to it**: the hook's `agent_id` marks the
   call waiting in that sub-agent's activity, or the sub-agent itself while its activity is not
   read, and the palette says which sub-agent asks. The agent's own request never lands on a
   sub-agent running beside it.

## Consequences

- A sub-agent's activity lives only in the snapshots handed out, like the rest of a conversation
  (ADR 0025): nothing is written anywhere.
- Background Bash commands are notified the same way; they are left to another issue.
- A future CLI shape falls back on what the main transcript says: a block with its state and
  answer, and an activity that is not found.
