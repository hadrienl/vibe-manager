# 0027 — The context column in sections

- Status: accepted
- Date: 2026-09-26
- Issue: [#66](https://github.com/hadrienl/vibe-manager/issues/66)
- Mockup: [`0027-inspector-sections/mockup.html`](0027-inspector-sections/mockup.html), validated on
  the issue before implementation

## Context

The right column had grown one content at a time, and each had changed its structure: Git and the
activity (#36) sharing the top behind a segmented picker, the notes under them past a divider one
point thick, then the agent, its usage (#18) and the initial prompt folded together behind a
header of their own, the prompt folded once more inside. Three kinds of fold, an order nobody could
change, and every new content another change of layout.

## Decisions

### A section declares itself, it is never placed

The column is a stack of sections of one kind (`InspectorSectionStack`). A section is a
descriptor — identifier, title, icon, sizing, a summary shown once folded, actions on the right of
its header, its content — and nothing else: where it goes, whether it is folded and how tall it is
belong to the arrangement. `SessionContextInspector` only declares six of them: Activity, Git,
Notes, Agent, Usage, Initial prompt. A section with nothing to show in this window — no journal,
no usage tracking — is left out of the stack and keeps its place in the arrangement.

Adding a section is adding a descriptor; a test lays out a seventh one, `test.fake`, without a
line of the stack changing.

### The arrangement is data, and outlives the build that wrote it

`InspectorArrangement` (in `VibeApplication`) holds, in display order, each section's identifier,
whether it is folded, and its weight: a share of the height relative to the other unfolded
sections, never a height, since the column's height is the window's. It is part of
`WorkspaceLayout`, common to every session.

- Identifiers are strings, not an enum. A section written by a later build decodes, keeps its
  place, is never shown and is written back as it was; a section new in this build is inserted
  right after the one declared before it, with its default state.
- An entry that cannot be read costs that entry only; a duplicate keeps its first occurrence; a
  weight that is not a positive number becomes 1.
- Move Up and Move Down count the sections shown only: a hidden one is never an invisible step.

The layout before this ADR is migrated on decoding, from keys read once and never written again:
the pane that was on top (`inspectorTopTab`) comes first and unfolded, the other folded under it;
`inspectorSplit` becomes its weight against the notes; `isSessionDetailsExpanded` folds or unfolds
the agent, usage and prompt together. What the user saw is what they get.

### Two ways to take height

A section either fills the height it is given and scrolls itself — Git, Activity, Notes: a list,
an editor — or is never taller than its content, which the stack puts in a scroll view of its own
and measures — Agent, Usage, Initial prompt. Without the second, a usage of four lines would take
a third of the column, and the column would be back to the arbitrary 45 % it had.

`InspectorHeights.distribute` shares the room left by the headers and handles in proportion to the
weights, settling first any section below its minimum, then any above its content, and sharing the
rest again. When the minimums do not fit, each section gets its own and the column scrolls as a
whole; otherwise it never does, and each section scrolls on its own — a list of thousands of files
never pushes the notes out of reach. What no section takes is left empty at the bottom; all folded,
the headers stay together at the top.

### Handles

`SplitHandle`, the web view's divider (#69), takes a vertical axis and sits between each unfolded
section and the next unfolded one: nine points to grab, a line of three points in the accent colour
on hover, focus and drag, the resize cursor. It stops at each section's minimum and at a fitting
section's content. The heights move on screen while it is dragged and become weights once it is
let go, never at each point. A double click shares the two neighbours equally: fitting to content
means nothing for a list or an editor, and the fitting sections already fit. VoiceOver adjusts it
by five percent of the pair, and names both sections; with Full Keyboard Access, Tab reaches it and
the arrows move it.

### Moving a section

A header is dragged within the stack by a gesture of its own, not through the pasteboard: the
insertion mark shows where it lands, and a header let go over the terminal types nothing into it.
Its menu offers Collapse / Expand, Collapse Others, Move Up (⌥⌘↑), Move Down (⌥⌘↓) and Reset Column
Layout; the same actions are VoiceOver actions of the header, and ⌥⌘↑ / ⌥⌘↓ work while it has the
focus. Reset Column Layout is also in the View menu.

A click on a header folds or unfolds it; with Option, every section.

### Focus

Edit Notes (⌥⌘N) unfolds the notes before giving them the keyboard. Focus Inspector (⌥⌘3) goes to
the first of Activity and Git the user left unfolded, and unfolds Git when neither is.

### The column's own width keeps the system divider

The left edge of the column is the divider of `.inspector` (ADR 0008): the system's cursor, grab
area and behaviour, the same as the sidebar's. Replacing it with a `SplitHandle` would mean giving
up `.inspector` for a stack of our own, and with it the toolbar above the column, its native fold
and the measured widths of ADR 0008. It is kept.

## Consequences

- `InspectorSplit`, `SessionPane`, the segmented picker, `InspectorTopTab` and the three layout
  keys are gone; the notes' and usage's own headers moved into their sections' headers.
- The initial prompt is shown whole: the section folds, the prompt no longer folds inside it.
- The Git list keeps its `DisclosureGroup`s and the guard against `_DisclosureGroupContainer`
  (`SessionContextInspector.swift`): nothing stands between its `List` and them.
