# 0021 — Distribution: Developer ID, notarized, a disk image on GitHub Releases

- Status: accepted
- Date: 2026-09-24
- Issue: [#19](https://github.com/hadrienl/vibe-manager/issues/19)

## Context

The V1 has to reach people who did not build it. ADR 0001 ruled out the Mac App Store: the
application runs developer tools in folders the user chooses, which the App Sandbox forbids. The
build already had the hardened runtime in Release, and nothing else: no export options, no
notarization, no disk image, a version edited by hand, and a CI that had never compiled Release.

Two constraints come from the rest of the design. The terminal host is the application's own
binary, and each end checks the other against its designated requirement (ADR 0017): a release
signed without a team would let any ad hoc binary of the same user carrying the bundle identifier
talk to the host (security review A6). And agents kept running across an update must be taken back
by the new version, which only works if the designated requirement survives the update.

## Decisions

### Developer ID and notarization

Releases are signed with the maintainer's Developer ID Application certificate, with the hardened
runtime and a secure timestamp, notarized by Apple and stapled. The designated requirement then
names the bundle identifier and the team: it is the same from one version to the next, so the host
of version N accepts the application of version N+1, and an ad hoc impostor is refused.

No entitlement is needed and none is granted. `release.sh` fails if the signed application carries
any.

### A disk image on GitHub Releases, no automatic update

The distributed file is a disk image made by `hdiutil` — no third-party tool — holding the
application and a link to `/Applications`, itself signed, notarized and stapled, with its SHA-256
beside it. It is attached to a **draft** release on GitHub; the draft is published by hand once the
[release checklist](../release-checklist.md) is ticked.

There is no Sparkle in V1: it is a dependency, an EdDSA key to keep and an appcast to host, for a
release rhythm that does not need it yet. A ticket of its own reopens it after the V1.

### Built on the maintainer's Mac, not in CI

`Scripts/release.sh <version>` runs where the certificate and the notarization credentials already
are: the login keychain, the latter stored by `notarytool store-credentials` and never written to a
file or an environment variable. Importing the certificate into GitHub Actions would expose the key
to every workflow change, for a gain a monthly release does not need.

The script refuses to go on at the first step that fails: a clean tree on `main` equal to
`origin/main`, no existing tag, CI green on the commit, the certificate present; then the archive,
the export, the checks of the signature (strict verification, no entitlement, hardened runtime, a
requirement naming the team, the bundle's identifier and version, `mock-agent.sh` sealed, no
`Local.xcconfig`), notarization, the disk image and its own notarization, the checksum and the
draft. `--dry-run` stops before notarizing and drafting.

### The version is given to the build

`MARKETING_VERSION` is the version asked for, `CURRENT_PROJECT_VERSION` the number of commits on
`main`, both passed to `xcodebuild` rather than written to the repository: a release commit that
only bumps a number is a commit nobody reviews.

### What proves a release

- CI builds Release on every pull request, so whole-module optimization and dead stripping are
  never first compiled on release day.
- `Scripts/clean-install-check.sh` takes the disk image as a user would: Gatekeeper, a folder of its
  own, TCC reset for the bundle, the interface smoke test against that binary, and the host refusing
  an ad hoc binary under the application's identifier.
- The checklist adds what only a person can check: a fresh macOS 14 virtual machine, VoiceOver and
  the keyboard, three real agents for fifteen minutes, memory with `footprint` and `leaks`, an update
  with agents kept running, and the TCC measurement ADR 0017 left open, which blocks the release if
  the access is not attributed to Vibe Manager.

`mock-agent.sh` ships in the release bundle: sealed by the signature, enabled only by
`VIBE_ENABLE_MOCK_AGENT`, it is what lets the smoke test run against the notarized build (security
review A8).

## Consequences

- A release needs the maintainer's Mac, and takes the time of two notarizations.
- Users update by downloading the next image. Agents kept running survive it.
- The first release candidate is drafted by running the script with a `-rc.1` version; it is
  marked as a pre-release.

## Rejected alternatives

- **An unsigned build with instructions to bypass Gatekeeper.** Teaches users to disable a
  protection, and leaves A6 open.
- **Signing in CI.** See above.
- **A Homebrew cask.** Worth considering after the V1; it would download the same notarized image.
