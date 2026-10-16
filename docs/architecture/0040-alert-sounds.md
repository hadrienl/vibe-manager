# 0040 — Alert sounds

- Status: accepted
- Date: 2026-10-16
- Issue: [#393](https://github.com/hadrienl/vibe-manager/issues/393)

## Context

A session out of sight that needs the user — a request (#40), a reply, a failure or a stop
(#236), a coordinator's call (#352) — was signalled by a notification with the system's default
sound, and by no sound at all while the application was in front or the floating panel (#41)
replaced the notifications. #393 lets the user choose that sound: the system's default, none, one
shipped with the application, one of macOS, or one of their own — imported from a file, or
composed by an agent from a description.

## Decisions

### One sound, one rule

The sound marks "a session out of sight needs you", whatever the reason: one sound for all, no
sound per kind of request. When a notification is posted, it carries the sound, so that Focus and
the "Play sound for notifications" switch of System Settings apply without anything of ours. When
none is posted — the application in front, or the floating panel in place of the notifications —
`AppModel.soundAttention()` plays it directly; the session on screen never sounds, the requests
read back at launch or replayed do not either, and several signals within a second sound once. With the notifications turned off and no floating panel, the
user asked for silence: nothing plays, in front either. "None" keeps the notification and drops its sound. The
dictation's "model ready" sound (#340) is not an attention signal and keeps Glass.

A sound played directly does not know about Focus: reading it needs the Focus Status permission,
which #393 does not ask for. In front, the user is at the application; with the floating panel in
the background, the sound plays during a Focus.

### The sound in use is copied to `~/Library/Sounds`

`UNNotificationSound(named:)` plays a file of the application's bundle or of `~/Library/Sounds`
only. The user's own sounds live in the data folder, and the shipped ones are made at first use
(below), so the sound in use — whatever it is but the default or none — is copied there as
"<application name> – <sound>.wav" (`NotificationSoundFolder`), in place of the previous copy, and
removed when the user changes it to the default or none — never when the library is merely read,
so that another run under the same name, a smoke test, never takes the user's sound away. Codex does the same with its own sound.
The file also appears among the alert sounds of System Settings: the price of a notification
that plays the sound chosen. A copy of the application under another name — a test build — owns
its own file and leaves the others alone; a test never writes there (no bundle, no copy).

A sound chosen and gone since — deleted, on a disk no longer there — plays the system's default,
without an error and without rewriting the choice.

### The user's own sounds: a library on the avatars' model

`FileAlertSoundLibrary` keeps `Sounds/library.json` and one WAV per sound, 16-bit PCM, beside the
avatars (#154): folder `0700`, files `0600`, the file written before the index names it, an index
that cannot be read set aside rather than written over. 50 sounds at most. An import reads the file
with the system's decoders (`AudioFileAlertSoundDecoder`), refuses one longer than 30 seconds — the
most a notification plays — before decoding it, mixes it to one channel and writes it as a WAV.
Neither an import nor a composition puts a sound in use: "Use This Sound" does, as for an avatar.

The page follows Settings › Notifications › Avatars: a row in Notifications (shape, menu, ▶,
"Manage Sounds…"), a page with the list, the dashed "Create a Sound" card, and a preview.

### A sound from a prompt: the agent writes a recipe, the application plays it

Three ways were weighed for a sound made from a description, at no cost:

| | A. Recipe for a synthesizer | B. A script of the agent's | C. A local text-to-audio model |
|---|---|---|---|
| Sounds | Clean synthetic tones, no realistic effects | Whatever the script does | Realistic effects |
| Delay | A theme's: 10 to 40 s of agent, rendering under 50 ms | Agent plus a run | Minutes at first, then seconds |
| Weight | Nothing to fetch | Python/numpy, SoX or ffmpeg, often missing | Several GB of model |
| Safety | The agent has no tool; its answer is data held to a schema | Runs generated code | Third-party weights, licences to check |
| Changes ("lower") | The current recipe is sent back, as the current theme is | In part | A new generation |

A is chosen. The agent runs as for a theme (#118, ADR 0033): its own CLI and account, outside any
session, from an empty temporary folder, without tools, MCP servers, hooks nor memory, its answer
held to `AlertSoundSchema` — up to 4 voices (sine, triangle, square, sawtooth, noise) with an
envelope and an optional low-pass filter, up to 16 notes each by name (`E5`, `F#3`), an optional
echo. `AlertSoundRecipe.problems` checks what a schema cannot — bounds, note names, 3 seconds at
most with releases and echo — and an answer refused is sent back once with its problems.
`AlertSoundSynthesizer` plays the recipe with plain arithmetic: mono, 44.1 kHz, brought to −1 dBFS,
the same samples every time. A composed sound keeps its recipe and what was asked, so that "What
should change?" starts from it; the versions made during a run can be heard and put back.

The four shipped sounds (Chime, Drop, Signal, Tick) are recipes too, made by the same synthesizer
at first use into the data folder: no audio file in the bundle, no licence to check.

B and C are left out: B runs code an agent wrote, C weighs gigabytes for an alert of a second.
