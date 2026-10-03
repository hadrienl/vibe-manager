# 0038 — First launch tour

- Status: accepted
- Date: 2026-10-03
- Issue: [#338](https://github.com/hadrienl/vibe-manager/issues/338)

## Context

A first launch opens on an empty window. #338 walks the user to a first session started, with
bubbles on the real interface: New Session, the draft's fields (#177), the new session's row and
its statuses (#80). Settings › General can start it again.

## Decisions

### The tour listens, it never acts

`OnboardingTour` (`VibeDomain`) is a pure value: `notStarted`, `step(step, session)` or
`finished`. What the user does is folded into it (`applying(_:)`), and an event the current step
does not wait for changes nothing. `AppModel` sends the events from the places those gestures
already go through: the draft shown, discarded or left empty, a session published, a status
written. The tour never creates, starts or moves anything itself: moving the session In Progress
starts its agent because #192 already does.

Six steps are counted — New Session, name, folder, options, prompt, statuses — and a closing bubble
outside the count. The statuses bubble asks for the move In Progress when the session waits in To
Do, and offers Next when it was launched at once.

### Kept across launches, reconciled at launch

The value is stored as JSON in the defaults (`onboarding.tour.v1`). At launch, once the store is
read (never on a store that could not be read), `resumed(hasSessions:contains:)` decides:

- a first launch starts the tour; an installation that already has sessions never sees it;
- a step inside the draft starts over at New Session, since the draft is not kept;
- a session gone, or archived, starts over at New Session.

`-onboarding.tourSuppressed YES` on the command line, as the interface smoke test passes it, turns
it off without writing anything.

### Two hosts for one bubble

Where the user types — the draft — the bubble is drawn in the window, over the draft, next to an
anchor (`anchorPreference` / `overlayPreferenceValue`): it never takes the keyboard, and it follows
its target as the draft scrolls. Where nothing is typed — New Session, the session's row — it is a
popover: an anchor does not leave a toolbar item or a cell of the sidebar's list (#96), a popover
does. Closed by the user, a popover stays closed until its target comes back or the tour moves on.

No bubble shows while a sheet is up (Full Disk Access first, at launch) or Open Quickly, nor while
another window is in front.

During the tour, Return in the draft's one-line fields goes to the next bubble rather than creating
the session, and Add to To Do is put forward at the prompt step; launching at once stays possible.
Escape keeps its meaning in the draft (#293): it discards the draft, and the tour goes back to New
Session.

The statuses bubble opens the row on its next statuses, as two fingers would, then puts it back.
With Reduce Motion, the row stays open, still, while the bubble is there.
