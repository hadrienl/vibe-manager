# 0023 — The session as a conversation

- Status: accepted
- Date: 2026-09-25
- Issue: [#38](https://github.com/hadrienl/vibe-manager/issues/38)

## Context

The terminal shows everything an agent does, and makes all of it equally loud: a thousand lines of
a test run weigh as much as the one sentence that says the fix is in. The applications people use
to talk to an agent show messages, and fold the rest under a title that says what it did. #38 asks
for that view next to the terminal, in real time, for Claude Code and Codex, with a composer that
writes to the agent, a theme the user chooses, and the terminal still the truth.

What the CLIs write was measured before anything was designed (80 transcripts of Claude Code
2.1.275 to 2.1.282, 30 rollouts of Codex 0.156 and 0.157, keys only):

- Claude Code writes one line per content block, not per message; a tool call's result comes back
  on a `user` line naming it by `tool_use_id`, with a structured `toolUseResult` beside it — the
  patch of an edit, the output of a command, the sub-agent a task started. That result also
  carries the whole file an edit touched (`originalFile`). A resume appends to the same file. Only
  13 % of reasoning blocks carry their text; the others hold a signature. Transcripts reach 58 MB.
- Codex writes every finished item as `event_msg/item_completed`, already typed — `UserMessage`,
  `AgentMessage`, `Reasoning`, `CommandExecution` with a `parsed_cmd` that tells a read from a
  search, `FileChange` with a unified diff per file, `McpToolCall`. Only finished items are there:
  a call still running is a `response_item` whose output has not come yet. Reasoning summaries are
  almost never written (12 of 2,102).
- Neither writes the answer word by word.

## Decisions

### A structured source, or no conversation view

The view reads the files the CLIs write, never the terminal's output, whose drawing is not an
interface. `claude -p --output-format stream-json` was rejected: it replaces the TUI rather than
adding to it. A provider opts in with `AgentConversationReporting` — which files hold a
conversation, a decoder for them, how a prompt reaches it — and a provider that does not has
terminals only. The Claude Code transcript is the one its last `SessionStart` named (ADR 0022),
which follows a `/clear`; failing that, the one named after the resume identifier.

A message appears when the CLI has written it, block by block; the activity line of #45 says
"writing…" meanwhile. That is what "no perceptible delay" means here.

### What was said is read to be shown, and for nothing else

ADR 0019 never reads what was said. The conversation view cannot do otherwise, so the rule narrows
rather than disappears: the content lives in memory, in the models of the views on screen, and is
never written by the application, never logged — diagnostics hold counts and type names — and
never sent anywhere. Transcripts are never modified.

### What a transcript says is not trusted

It holds what a repository, a web page or an MCP server made the agent write. Only `http`,
`https` and `mailto` links are links; no remote image is loaded (an image is a link to itself); no
HTML is interpreted. The file a diff names is shown in the Finder, never opened: opening an
application or a `.command` an agent was made to write would run it. A command's output is kept to 32 KiB (its start and its end), a diff to 2,000
lines per file and 500 drawn; `originalFile` and base64 images are never decoded into the model.

### Lines in the order they were written

The `parentUuid` tree of a Claude Code transcript is not followed: parallel tool calls branch it on
nearly every turn (38 of 60 transcripts), and walking back from the last line would hide what the
agent did. A conversation rewound with `/rewind` therefore still shows what was abandoned.

### Following a file

`FileTranscriptTail` hands over whole lines only, resumes at its offset, and reads a file that got
shorter or changed inode again from the start after a `.reset`. A `vnode` source wakes it, a
one-second poll underneath covers a file that does not exist yet or was replaced. A snapshot is
published only when lines arrived, and the folders are looked at again every two seconds while a
file is awaited, every ten after. Only the five sessions last shown in conversation keep a model
and a reader; a hidden conversation view is disabled, so that its composer never keeps the
keyboard.

### Titles, groups, and the state that shows folded

`ToolCallSummary` writes the titles — "Read Session.swift", "swift test — 42 tests passed" — and
`ConversationGrouping` folds consecutive calls of the same family into one block ("5 files read"),
the most serious state of its calls showing on it. Both are pure. A test summary is recognised only
for a command that runs tests, from a closed list of runners: `cat` of a CI log is not a test run.
Consecutive reasoning is one row; reasoning a provider kept to itself says so and does not unfold.

### The composer writes as a keyboard

A prompt is written into the session's terminal: a bracketed paste, then, 80 ms later, the key
that sends it. Measured against Claude Code 2.1.282 and Codex 0.157.0 in a real pseudo terminal:
both take a paste of several lines as one prompt and keep its line breaks. During a turn Codex
sends a prompt given Return into the turn under way and queues one given Tab; Claude Code queues
either way — each provider declares the key. Every control character but the line break and the
tab is removed first, so that a pasted text cannot close the paste or send a sequence of its own;
a joined file whose path holds one is not written at all.
The composer is closed while the agent waits for an answer in its terminal, where a prompt would
be read as the answer. Files joined to a prompt are written as paths escaped the way Terminal.app
drops them. The sent prompt shows as an echo until the transcript has it; after ten seconds without
it, the view says so and offers the terminal.

### Conversation by default, switched per session

The Settings choose how sessions open (conversation by default); each session keeps what the user
switched it to, in `WorkspaceLayout`, next to the rest of the interface's state. ⌥⌘T switches. Both
views stay mounted, like the terminals, so switching is instant and each keeps its place.

### Themes, and a tab of their own

Every colour and font of the view comes from a `ConversationTheme` in the environment. Six are
shipped — System Light, System Dark, Paper, Night, Terminal, High Contrast — and a test holds every
pair a reader must read to WCAG's 4.5:1 (3:1 for state symbols), in every theme and with every
accent. The system's appearance picks between a light and a dark theme; more contrast asked of
macOS gives High Contrast unless the user chose another theme. Fonts are any installed family, the
code font any fixed-pitch one; a family no longer installed falls back to the theme's. All of it is
in Settings › Conversation, a tab of its own.

### Markdown by swift-markdown, code by its words

GitHub-flavoured Markdown is parsed by `swiftlang/swift-markdown`, pinned exactly at 0.6.0, the
last release whose manifest the Swift 6.1 of CI's Xcode 16.4 reads, and confined to
`VibeConversationUI`. Code is coloured by a lexical highlighter of our own for a dozen languages,
which never changes the text.

## Consequences

- A session whose agent has not written yet shows "has not written anything yet"; one whose agent
  writes nothing readable shows its terminal.
- A new agent needs a decoder and a prompt format to have a conversation view; the mock agent
  writes Claude Code's format when `VIBE_MOCK_TRANSCRIPT_DIRECTORY` names a folder.
- The composer cannot see what was typed into the TUI's own prompt: a prompt sent while the user
  had started a line in the terminal is appended to it.
- A transcript the CLI deleted (Claude Code, after 30 days by default) leaves the conversation
  empty; the terminal's own history is not kept either (ADR 0004).
- Personal themes — duplicating one to edit it, importing one — are left to a later issue.

## Rejected alternatives

- Parsing the terminal's output: its drawing changes with every release, and #45 refused it too.
- `stream-json`, or Codex's app-server, as a second channel: it would diverge from what the
  terminal shows, and cannot attach to the TUI's own session.
- Following `parentUuid` to hide rewound branches: it hides the results of parallel calls.
- `AttributedString(markdown:)` alone: no headings, tables or code blocks as blocks. MarkdownUI:
  in maintenance.
- A second executable or a web view for rendering: nothing the SwiftUI views cannot do.
