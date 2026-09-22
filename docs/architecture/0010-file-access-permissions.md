# 0010 — Asking for file access once

- Status: accepted
- Date: 2026-09-22
- Issue: [#31](https://github.com/hadrienl/vibe-manager/issues/31)

## Context

Creating a session used to fire a burst of macOS consent alerts — one per protected folder —
right at the moment the user wanted to watch their agent start. The application is not sandboxed
(ADR 0001), but TCC still guards Desktop, Documents, Downloads, iCloud Drive, removable volumes
and network volumes, and three things were reaching into them at once: the agent itself, the
validation of the working folder, and the open panel.

The agent is the deepest of the three. The CLI runs in a pseudo-terminal spawned by the
application (ADR 0004), so *Vibe Manager* is the responsible process at TCC's level: every
protected folder Claude Code or Codex reads is requested in the application's name.

## What was the development build, and what was the product

The ticket asked for this to be settled before anything was designed, and it was right to.

Measured on the build of the day: `codesign -dvvv` reported `flags=0x20002(adhoc,linker-signed)`,
`TeamIdentifier=not set`, `Internal requirements=none`. `Configuration/Shared.xcconfig` set
`CODE_SIGN_STYLE = Automatic` with no `DEVELOPMENT_TEAM`, so Xcode fell back to ad-hoc signing.

TCC keys a grant to the client's code identity. For a certificate-signed application that is the
bundle identifier plus its designated requirement — stable across builds. For an ad-hoc one only
the `cdhash` is left, and **it changes at every compilation**: any grant given, whether a Full
Disk Access switch or a folder designated in the open panel, was already void at the next build.

| Symptom | Cause | Where it is fixed |
|---|---|---|
| Alerts return after a grant, at every build | ad-hoc signature, moving `cdhash` | build configuration |
| The Full Disk Access entry is useless the next day | same | build configuration |
| One alert per protected folder, mid-creation | nothing was asked or explained beforehand | product |
| Alerts that do not say why | no usage description declared | product |
| The folder read while the user types | validation opened the disk on every keystroke | product |

`Shared.xcconfig` now ends with `#include? "Local.xcconfig"`, an unversioned file each machine
fills with its own `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = Apple Development`;
`Local.xcconfig.example` documents it. The include is optional, so `Scripts/ci.sh` and CI — which
build with `CODE_SIGNING_ALLOWED=NO` — are untouched. Committing a team identifier would bind the
repository to one account, so it stays local, and the README says so: without it a developer keeps
seeing the alerts, and that should be known rather than rediscovered.

## Decisions

### One permission, asked once, at launch

macOS offers exactly one grant that covers folders an agent may freely decide to read: Full Disk
Access. It cannot be requested programmatically, so the application detects that it is missing,
explains it, opens the right pane of System Settings, and says that the change takes effect at the
next launch. That is the path Terminal, iTerm2, Ghostty and Warp take, and the only one that keeps
the promise of "once and for all".

The step is presented at launch and nowhere else. Asking during session creation would reproduce
exactly the interruption this ticket exists to remove.

### Two states, because the system offers no third

`FullDiskAccessStatus` is `granted` or `notGranted`. There is no status API for this service, and
nothing lets a process tell "never asked" from "refused": both look identical from inside. A third
case would be an invention, and every screen reading it would be showing a guess.

### The probe must not raise the alert it exists to prevent

The status is read empirically, by opening `~/Library/Application Support/com.apple.TCC/TCC.db`:
it exists on every Mac, and only Full Disk Access opens it. Crucially, a process without the
access is refused *silently* — the path is hidden rather than denied (`errno = 2` observed), with
no alert. Nothing is read from the file; being allowed to open it is the whole answer.

### Probed once per launch, except where the user is looking

TCC freezes a process's permissions when it starts, so the answer cannot change under a running
process. `FullDiskAccessGate` caches it, and that same fact is why the step has to talk about
relaunching rather than waiting for the user to come back.

The settings window is the exception, and asks again through `refreshedStatus()`. Someone who
opens it has usually just come back from System Settings, and a row that kept saying "Not granted"
because the question was settled at launch would be a row that lies. One file open is a small
price for that.

The step itself is offered at most once per launch, in the gate rather than in the interface:
recording the answer is what makes it final across launches, but that write is asynchronous, and a
second caller reading the preferences inside that window would otherwise be told to present a step
the user is already reading.

Nothing is ever warned about on a guess. Until the first probe has answered, the status is `nil`,
and the creation sheet says nothing about a protected folder: telling someone who granted the
access long ago that macOS is about to interrupt them would be worse than staying quiet.

### The application stores the answer, never the access

`UserDefaultsPermissionPreferences` records only that the step was answered. Whether access is
granted is probed at every launch, so an access turned off in System Settings cannot leave a stale
"yes" behind in the preferences.

The step does not come back: not once access is granted, because the status alone settles it; not
after a refusal, because the answer was recorded. The way back is the Settings window, which gets
its first real row here — a permanent entrance, rather than something that surges up unbidden.

### No folder is proposed any more

The creation sheet used to open on the home directory. It is the one place that contains Desktop,
Documents and Downloads without being guarded itself, so the remark said nothing and accepting the
default sent an agent straight into all three. The sheet now opens with the field empty: choosing
is always a gesture, and the open panel grants the access along the way. The panel still starts in
the home directory, because it has to start somewhere.

### An ad-hoc build says so

A build phase warns, in Debug only, when `DEVELOPMENT_TEAM` is empty — the state in which macOS
forgets every permission at the next compilation. It warns rather than fails: a fresh clone must
still build, and CI must stay untouched.

### Refusing is an answer, not a failure

A user who refuses works in their own repositories, which are almost never in a protected
location: they will simply never see an alert. Nothing is disabled, nothing is greyed out, and no
banner sits over the workspace. The creation sheet says something only when the designated folder
*is* in a protected location — a remark under the field, never a problem, never blocking.

That remark is made from the path alone (`ProtectedFileLocation`). Reading the folder to find out
would raise the very alert the line exists to announce.

### Validation stopped reading the disk

`CreateSession.problems(with:)` no longer opens the working folder; `checkingFolder` has to be
asked for. Typing a path is not a request to read it, and the debounced revalidation of the sheet
was opening `~/Documents` while the user typed.

The folder is now checked at two moments, and only two: when the open panel hands one back — the
continuation of a gesture the user just made, through the system's own panel — and at creation,
which already re-checks everything (ADR 0007) and is the last place a folder that disappeared can
be caught.

A folder already opened once in this session keeps being checked afterwards, because the consent
it may have needed has been given and re-opening it says nothing new to the system. Without that,
a folder that had disappeared vanished from the list of problems as soon as the next field was
edited, and came back only at the following Create — a form contradicting itself.

The open panel itself remains the one place an alert can legitimately appear without Full Disk
Access: outside the sandbox it runs in-process, so browsing into Desktop from it may prompt.
It answers an explicit gesture, at the moment it is made, and it disappears with the grant.

### The chosen folder survives by the signature, not by a bookmark

Once the code identity is stable, the grant obtained through the open panel is recorded by TCC
against it and survives relaunching. No bookmark is stored: a security-scoped bookmark requires
the sandbox entitlement and is out of reach here, and an ordinary bookmark confers no right at all
— it only re-finds a folder that moved. That service belongs to #12, not to a ticket about system
alerts.

### The agents keep prompting in the application's name

`posix_spawn` could disclaim responsibility for the child
(`responsibility_spawnattrs_setdisclaim`), and the alerts would stop being raised in the name of
Vibe Manager. They would be raised in the name of a command-line binary, which TCC refuses without
asking anyone — trading alerts for silent denials in the middle of an agent's work. The PTY is
left as it is, and the attribution is accepted: it is exactly what Full Disk Access covers.

### Usage descriptions, so an alert says why

`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
`NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`,
`NSNetworkVolumesUsageDescription` and `NSFileProviderDomainUsageDescription` are declared in
`Shared.xcconfig`. They change neither the number nor the timing of the alerts — only what they
say — which makes them matter precisely in the case where alerts remain: the user who refused.

## Out of scope

Sandboxing the application (ADR 0001, and incompatible with launching arbitrary CLIs). Permissions
unrelated to files — microphone, automation, accessibility. Restricting what an agent reads once
it runs: this ticket is about system alerts, not about an in-application permission policy.
Developer ID signing and notarisation for distribution (#19).
