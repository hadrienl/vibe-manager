# 0033 — Automatic updates: Sparkle 2, a feed on GitHub Pages, agents kept running

- Status: accepted
- Date: 2026-09-29
- Issue: [#92](https://github.com/hadrienl/vibe-manager/issues/92)
- Supersedes: ADR 0021's "A disk image on GitHub Releases, no automatic update", for the part
  about updates. The disk image stays what a first installation downloads.

## Context

ADR 0021 shipped the V1 as a notarized disk image, attached to a GitHub release drafted by a tag
and published by hand once the release checklist is ticked. Updating meant downloading the next
image. It left Sparkle out — a dependency, a key to keep and a feed to host — and said a ticket of
its own would reopen it.

Two things of the rest of the design weigh on an update. The terminal host is the application's
own binary, and keeps running the agents the user chose to leave running (ADR 0017): an update
replaces the bundle under it. And three checks rest on the designated requirement — TCC's Full
Disk Access (#76), the host's peer verification (security review A6), and now Sparkle's own —
so it must be the same from one version to the next.

## Decisions

### Sparkle 2, not an installer of our own

Replacing a running bundle, checking two signatures, going back when it fails, installing into
`/Applications` without its rights: that is Sparkle's work, done for most Mac applications
distributed outside the App Store, with the window their users expect. An installer written
against the GitHub API would cost more for something less proven.

Sparkle is a package dependency pinned exactly, `2.10.0`, in a target of its own, `VibeUpdates`,
behind the `SoftwareUpdating` port of `VibeApplication`. Only the application links it: the
package's tests have no bundle an updater could replace. The application is not sandboxed
(ADR 0001), so no entitlement and no XPC service is needed; the framework's services are left
where Sparkle puts them, unused, and sealed by the signature like the rest.

### The feed on GitHub Pages, computed from the published releases

`https://hadrienl.github.io/vibe-manager/appcast.xml` is the feed. The workflow `Appcast`
recomputes it **whole** from the list of releases whenever one is published, unpublished, edited
or deleted, and deploys it with the `site/` folder, where a landing page will come. GitHub
Releases stays the one source of truth: nothing is edited by hand, nothing is kept between runs,
and a release unpublished is gone from the feed at the next run.

- **A draft is never offered.** The generator skips `draft` releases before reading anything of
  them, and the workflow only runs once a release is published.
- **Two channels.** A final version has no channel: every copy sees it. A pre-release
  (`1.2.0-rc.1`, published as a GitHub pre-release) is on the channel `unstable`, which only the
  copies set to Unstable in Settings → Updates see. There is no beta channel.
- **The ten latest of each**, sorted by build number.
- **Release notes** are the release's own, up to the marker `<!-- release-checklist -->`: the
  filled-in checklist below it stays on GitHub and never reaches the update window. They are
  rendered to HTML by swift-markdown, the parser the application already pins. A release without
  the marker links to its page instead.
- **The host's protocol** is in each entry, `<vibe:hostProtocol>` (below).

`releases/latest/download/…` was rejected: it ignores pre-releases, and cannot carry two channels.

The generator is `Packages/ReleaseTools`, a package of its own with its tests, run by CI; the
workflow calls it through `Scripts/publish-appcast.sh`.

### Everything signed is signed at the tag

`Scripts/release.sh`, in the protected `release` environment, adds a step after notarization:

1. `VibeManager-<version>.zip`, the stapled application compressed by `ditto`, as Sparkle
   recommends.
2. Its EdDSA signature by the `sign_update` of the same Sparkle version, downloaded and checked
   against a pinned digest like the Apple intermediates.
3. That signature checked against the `SUPublicEDKey` **the application carries**
   (`Scripts/check-update-signature.swift`): proof that the copies in the field will accept it,
   which `sign_update --verify` alone is not.
4. `VibeManager-<version>.appcast.json`: version, build, archive, length, signature, minimum
   system and host protocol — everything the feed needs, attached to the draft.

The feed's workflow reads those files and holds no secret. A compromised feed could only point at
archives that must still pass both signatures.

### Two signatures, and the same requirement

Sparkle installs an archive only if its EdDSA signature verifies **and** the application inside is
validly signed with the same Developer ID (`SUVerifyUpdateBeforeExtraction`: the EdDSA signature
is checked before anything is extracted). Feed and archives travel over HTTPS only.

`release.sh` compares the built application's designated requirement **for equality** with
`Configuration/DesignatedRequirement.txt`. The requirement names the bundle identifier and the
team, not a certificate: renewing the Developer ID certificate changes nothing. Changing it is a
reviewed change of that file — and a decision to lose Full Disk Access and every agent left running
on the day of the update. The file is the reference: the archive is not compared with the application of the
release before it, whose requirement that same file already fixed, and Sparkle refuses an
application signed by another team anyway.

### The key

The public key is in `Info.plist`, from the build setting `VIBE_UPDATE_PUBLIC_KEY` of
`Configuration/Shared.xcconfig`. The private key was made once by `generate_keys`, and lives in the
maintainer's login keychain, in a copy kept offline, and in the secret `SPARKLE_ED_PRIVATE_KEY` of
the `release` environment. A build whose key is empty never looks for updates, and `release.sh`
refuses to release it.

**Rotating it**, lost or leaked: Sparkle accepts an update signed with a new EdDSA key as long as
its Developer ID signature is the same — never change both at once. Publish a version whose
`SUPublicEDKey` is the new key, signed with the old key if it is still there, with the new one
otherwise (the Developer ID signature bridges); every later version is signed with the new key.
Never rotate it on the day the Developer ID certificate is renewed. The steps are in
[operations](../operations.md#rotating-the-update-key).

### Build numbers

`CFBundleVersion` is the number of commits of `main`, as before. A final version is built from the
commit of its last release candidate, so both would have the same number, and Sparkle would never
offer `1.0.0` to a copy of `1.0.0-rc.3`. A final version therefore gets `<commits>.1`: later than
its candidate, earlier than anything built on a later commit. Sparkle's own comparator does the
rest; a custom one is deprecated in Sparkle 2.10.

### Who updates

The updater starts only in a copy signed with a Developer ID, with a public key, outside an
isolated data directory (`VIBE_DATA_DIRECTORY`) and without `VIBE_UPDATES=off`. A build of the
source — signed Apple Development or ad hoc — is never replaced by a release, and a test copy
running beside the real one never updates itself. The menu item and the tab stay, and say why.

Checks are automatic by default, once a day; downloading and installing by itself is off by
default and, when on, installs only when the user quits. A scheduled check never takes the focus:
shown when the application comes forward, otherwise said in the menu (Sparkle's gentle reminders).

### Installing is quitting

An update relaunches the application through the quit of ADR 0017, and nothing else. Sparkle asks
before relaunching (`shouldPostponeRelaunchForUpdate`), and `DecideUpdateRelaunch` answers:

| Situation | What happens |
|---|---|
| Sessions being restored (#11), or a sheet or an alert open | Put off, without a word, until that is over |
| No agent running in the host | Relaunched |
| Agents running, quit setting Keep running / Stop them | That answer, without asking |
| Agents running, quit setting Ask | **Install Vibe Manager 1.2.0 and relaunch?** Keep Running and Install / Stop All and Install / Later |
| Agents running, and the new version speaks another core of the host's protocol | **Vibe Manager 1.2.0 can't take back the running agents.** Later / Stop All and Install — Keep Running is not offered, even when it is the quit setting |

The answer is handed to the quit that follows, which does not ask again; everything after it is
the quit as it was — templates, notes, the six-second deadline, `DetachForQuit` or `PrepareForQuit`.
Later closes Sparkle's window — left waiting on a relaunch nobody starts, it could not be closed —
and keeps the version ready: the application menu offers **Install Vibe Manager 1.2.0 and
Relaunch…**, which asks again, and Sparkle installs it anyway when the application next quits. If
that version speaks another core of the host's protocol, that quit does not offer Keep Running
either: **Vibe Manager 1.2.0 will be installed as Vibe Manager quits** — Stop All and Quit, or
Cancel.

### After the relaunch

The host keeps running the binary it was started from, which no longer has a name. The new
version finds its socket, and verifies it. Sparkle deleted the old bundle, so the system cannot
even find the host's code any more: `SecCodeCopyGuestWithAttributes` fails with `ENOENT`, where a
rebuild, which writes a new file in the old one's place, gives `errSecCSStaticCodeChanged`. Both
fall back on what the kernel says of the running process — the fallback ADR 0017 added for a
rebuild, with the same identifier and team. Measured on the first update tested by hand (0.9.0 to
0.9.1): before `ENOENT` was part of it, the host was refused, the kept agent was killed as a
leftover and resumed natively, its turn lost. `hello` and `welcome`
speak the frozen core; the older host names its capabilities, and is asked for nothing it did not
name. The verdict is `detached`, and the sessions are adopted.

What that relies on is now tested rather than assumed:

- **The frozen core** is kept as it was on the wire in protocol 1: what such a host says is still
  read as it meant it, and what this build asks still carries every key it did
  (`TerminalHostCoreCompatibilityTests`).
- **A host of an earlier version**, offering no capability, is taken back with its running agent,
  and receives no request it did not offer (`TerminalHostTests`).
- **A host whose binary is replaced by a rename**, as Sparkle does, keeps its agent and is taken
  back (`TerminalHostProcessTests`).
- **The trampoline** of side terminals (#43): an older host starts their shells through the binary
  now at the application's path — the new one. `--terminal-exec <path> <argv0> <arguments…>` is
  part of the frozen core.

**If the core ever changes**, the socket changes name (`host-v2.sock`, ADR 0017) and the new
version could not find the agents left under the old one. The feed says which core each version
speaks (`<vibe:hostProtocol>`), and the relaunch then asks to stop them (above). An update
installed at a quit without that question — its feed not saying — must be handled by the version
that changes the core: it looks for the sockets of the cores it knows before concluding the host
is gone, and never reads a live host as a crash.

## Consequences

- A release is still a tag, an approval, two notarizations; it now also produces the archive, its
  signature and its entry. Publishing the draft publishes the feed.
- The first version that embeds Sparkle is installed by hand, from its disk image, over copies that
  have none. From the next one on, updates come by themselves; its notes say so.
- A copy on the Unstable channel receives every release candidate published.
- The release checklist tests an update by Sparkle from the version before, with an agent kept
  running, and Full Disk Access after it.

## Rejected alternatives

- **An installer written against the GitHub API.** See above.
- **`releases/latest/download/appcast.xml`.** Blind to pre-releases.
- **A feed kept in the repository and committed by the release.** A commit nobody reviews, and a
  state to keep in step with the releases, where Pages is recomputed from them.
- **Signing the feed** (`sign_update` on the XML). It would put the private key in the Pages
  workflow, for a feed whose archives are already signed twice.
- **Delta updates.** An archive of a few tens of megabytes does not need them yet, and they would
  need the previous archives at hand when the feed is made.
- **A beta channel.** One unstable channel carries the release candidates; a second would carry
  nothing.
