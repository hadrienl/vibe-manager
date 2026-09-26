# 0027 — Manual session order

- Status: accepted
- Date: 2026-09-26
- Issue: [#44](https://github.com/hadrienl/vibe-manager/issues/44)

## Context

The sidebar sorts sessions by last activity, creation date or name. None of those is the order a
user works in, and #44 asks to arrange them by hand, in the flat list and in the grouped one
(ADR 0025), with the two telling the same story. The rest of #44 — the scope picker replaced, the
archive at the foot of the sidebar, the flat and grouped views — was delivered by #80 (ADR 0024)
and #27 (ADR 0025).

## Decisions

### One order, kept in the sessions

Each `WorkSession` has a `rank`, smaller first. There is one order for the whole store: a column
(ADR 0024) and a group are subsequences of it. The flat list and the grouped one therefore agree by
construction — the grouping never sorts again, and the groups come in the order of their first
session.

The rank is stored in `sessions.json`, schema v8, rather than in the layout: it is an arrangement
of the work the user made by hand, and losing it costs more than a drag. A v7 store is ranked in
the order it was listed, last activity first, so choosing Manual at the first launch moves nothing.
A build that only knows v7 refuses v8, as for every earlier version, rather than dropping the ranks.

The store gives the rank. A session it does not hold yet enters at the top (`min - 1`), in the same
write as the session itself; a session it holds keeps its rank whatever the caller's copy says. A
restart, a status change, a close, an archive and an unarchive modify the session in place, so it
keeps its place without code of its own. Moving a session does not touch `updatedAt`: the rank is
not an activity, and the Last Activity sort must not move because of it.

### A move redistributes, it does not insert

A move hands the ranks the subset already held — the column, or the group — back to the same
sessions in their new order (`SessionOrder.redistribute`). Nothing outside the subset changes
place: the sessions of the other columns keep their positions relative to it, and a group keeps the
smallest rank it had. Inserting into the global order instead would let the first session of a
group, moved under the second, drop below another group's first session and carry its group with
it — a group the user never touched would jump.

A group is moved as a block: its sessions become contiguous at the new place among the groups, and
the ranks of the whole column are redistributed, those of folded groups included. The group of the
sessions without a folder stays last and does not move.

`SessionRepository.reorder` writes every rank of a move in one read and one write.

### Only in the Manual sort, with nothing narrowing the list

`SessionSort` gains `manual`. Dragging, Move Up and Move Down are only offered in that sort, with no
search and no facet: what is moved is then exactly the order that is stored. In any other sort a
drag would mean rewriting the user's manual order with the one on screen, and in a filtered list a
move would be relative to rows the user cannot see. The help tag of the sort menu says where the
order is found.

A drag never changes a session's column nor its group: the status changes by the swipe and the
menus of ADR 0024, and the folder is derived (ADR 0025).

### The list's own move, and a header that carries the drag

Rows are moved with `.onMove`, one `ForEach` per column or per group. The list draws no insertion
point outside the `ForEach` a row came from, which is how a drop in another group is refused. No
gesture sits on the rows (#96), so the list's drag is free.

The list cannot move sections, so a group's header carries its own drag, with its folder's path as
the payload — what a header dropped anywhere else would mean. The drop is taken only when it
carries the path of the header being dragged, so that a path dragged in from elsewhere later is not
mistaken for a drag that ended outside the window.

The keyboard has the same moves: Move Up and Move Down (⌃⌘↑, ⌃⌘↓, as in the prompt templates), and
Move Group Up and Move Group Down in the View menu, in the rows' and headers' context menus, and as
VoiceOver actions, which say the new position.

### Show Archived Sessions

The archive list at the foot of the sidebar (ADR 0024) is also opened by Show Archived Sessions,
⌥⌘A, which shows the sidebar first when it is hidden. Whether it is open moves from the view to
`AppModel` for that.
