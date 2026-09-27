# 0029 — The floating panel of requests, and its avatars

- Status: accepted
- Date: 2026-09-26
- Issue: [#41](https://github.com/hadrienl/vibe-manager/issues/41)

## Context

The palette of #40 (ADR 0026) answers the requests of background sessions, but only from inside
Vibe Manager: whoever works in another application has to come back to see that an agent waits.
#41 lets the palette float above the other applications, presented by an animated avatar that the
user can have an agent draw from a description, or import.

## Decisions

### One palette, two surfaces

The floating panel is another view of the same `PendingRequest`s, answered through the same
`AppModel.answer(_:to:)`. It has no request state, no routing and no arming rule of its own: what
ADR 0026 guarantees — what is allowed is what is seen, one answer in flight, every step checked
again before it is typed — holds here without a line more. `FloatingRequestPanelModel` only
decides whether the panel is on screen, which request its bubble shows, and whether it is folded.

- **Never twice.** The option on, the panel is shown when Vibe Manager is not the active
  application, or has no visible workspace window; otherwise the sidebar has its palette. While the
  option is on, no system notification is posted for the requests: the bubble is the signal, and a
  banner would say the same request twice. The Dock badge stays.
- **The selected session included.** #40 leaves the selected session's requests to its terminal,
  because the keyboard goes there. With another application in front, nobody types into it, and the
  user does not see it: its requests have their bubble.
- An application launched behind another one never resigns: at load, it now tells the model it is
  not in front when it is not.

### A panel that never takes anything

`FloatingPanelWindow` is an `NSPanel` with `.nonactivatingPanel`, at the floating level, on every
Space and beside full-screen applications (`.canJoinAllSpaces`, `.fullScreenAuxiliary`,
`.stationary`, `.ignoresCycle`). It is shown with `orderFrontRegardless()`, never made key by the
application; its hosting view accepts the first click. A button acts without taking the keyboard;
a text field takes it without activating Vibe Manager. ⌃⌥⌘P — a Carbon hot key, which needs no
accessibility permission, registered only while the panel is shown — lends it the keyboard;
Escape, a second ⌃⌥⌘P or an answer sent give it back by activating the application that had it.
"Open Session" is the one gesture that brings Vibe Manager forward.

The window takes the size of its content (the hosting view's intrinsic size, reported on every
change) and moves so that the avatar stays where it stands; the bubble opens toward the inside of
the screen. The avatar's place is kept per screen — by the display's UUID, as a point of its
visible frame from 0 to 1 — and the panel appears on the screen of the pointer.

### The animation is a pure state machine

`AvatarAnimation` takes events (a request arrived, the bubble shows one, an answer is being sent,
went through, failed) and instants, and says which expression to show and until when. Time and
blinks are given to it — the driver's clock, a seeded generator — so that the tests walk it
through every sequence without waiting. Reduce Motion leaves one still expression per mood.

The set of sprites is `AvatarExpression.allCases`. The tests check both ways that the machine can
show every one of them and no other, and that the generation prompt asks for exactly these: the
prompt and the animation cannot drift apart.

### Drawing like summarizing

A generation is one pass of the agent's CLI, as the journal's summaries are (#36):
`OneShotAgentRun`, extracted from `CommandLineSummarizer`, runs it outside any session, from an
empty temporary folder only its owner reads, removed afterwards, with a timeout. Codex draws with
its image generation tool:

```
codex exec --ephemeral --skip-git-repo-check --ignore-user-config --ignore-rules
  -s workspace-write --enable image_generation
  --disable hooks --disable apps --disable plugins
  -c mcp_servers={} -c tools.web_search=false [-i reference.png] -
```

The description is the user's; nothing else goes out — no session, no repository, no path — and
the run has nothing that could act. The image is read from the one file it was told to write,
never through a link. Claude Code produces no image: it is listed, unavailable, with that reason.

**One sheet, not ten images.** The spike of #41 drew ten images in ten calls as ten different
characters, of ten different sizes. Asked for one sprite sheet — a 5 × 2 grid — Codex keeps the
character, its size and its framing (80 s; 56 s without the user's configuration). One expression
is drawn again with the current sheet as the reference image (106 s), then scaled to the neutral
sprite's height and set on its line.

**A flat magenta, keyed out by the application.** Generators do not reliably draw transparency, so
they are asked for `#FF00FF`. `VibeAvatar` reads the background's colour from the sheet's border
rather than assuming it, keys it out with a soft edge, and takes the background's colour back out
of that edge so that no fringe stays. A border that is not flat falls back on Vision's foreground
mask; a sheet already transparent — Codex sometimes removes the background itself — is kept as it
is.

### Nothing is accepted unchecked

What comes back is not trusted: decoded by ImageIO within bounds read from the header (25 MB,
8192 px), cut along its grid, each cell measured — empty, cut by its edge, of another size than the
others, background left — against pure rules (`SpriteSetValidation`), framed the same way in every
sprite, and written again by the application as 512 × 512 PNGs, so that nothing of the original
file goes through. Every problem names its expression. What is made is a candidate: the avatar in
use changes only when the user uses it, and is replaced on disk in one rename.

### Archives

An avatar travels as a zip holding what its folder holds: `manifest.json` and one PNG per
expression. The archive is read in memory, without extracting it or running a tool: the central
directory is read first, every entry checked — no absolute path, no `..`, one root folder at most,
no link, no encryption, sizes as declared within bounds — and each entry inflated into a buffer no
larger than it declared, then checked against its CRC. Without a manifest, images named after the
expressions are enough, so that an avatar can be drawn by hand; an incomplete one becomes a
candidate whose missing expressions are generated before it can be used. The export includes the
description unless the user leaves it out.

**The default avatar is such an archive**, in `VibeAvatar`'s resources, read by the same code. The
one shipped is a placeholder drawn by `Scripts/render-placeholder-avatar.swift`; it is replaced by
an avatar made with the application and exported, by replacing the file. A test checks that it
reads and is complete.

## Consequences

- The option is off by default; off, #40 is unchanged.
- A new module, `VibeAvatar` (ImageIO, Core Graphics, Vision), keeps images and archives out of the
  rest; `VibeUI` sees it only through `AvatarImageProcessing` and `AvatarStore`.
- The panel is visible on every Space, including while the screen is shared: that is what the option
  is for, and it is off by default.
- Codex reads the user's global `AGENTS.md` even with `--ignore-user-config`: its instructions
  can cost a few needless commands in the temporary folder, and nothing more.
- Checked by hand only: the panel above a full-screen application and on another Space, the
  keyboard given back after a free-text answer, VoiceOver while another application is in front,
  two screens.
