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

### Built by a tag, in a protected environment

Pushing a tag `v<version>` on a commit of `main` runs `.github/workflows/release.yml`, and nothing
else does: not a push to `main`, not a pull request. A release is a decision, and two notarizations
per merge would buy nothing.

The Developer ID certificate and an App Store Connect API key (role Developer, enough to notarize)
are secrets of a GitHub environment, `release`, that requires the maintainer's approval before any
job reads them and is restricted to `v*` tags. The one action the job uses is pinned by commit, not
by tag. The script imports the certificate into a keychain of its own and writes the key to a file,
both deleted when it ends, whatever the outcome.

This was a trade. The certificate on the maintainer's Mac alone could not leak through a workflow;
in CI, anything that runs in the job could read it and sign as the team, and revoking it would
invalidate every build already distributed. The environment's approval, the pinned action and the
tag-only trigger narrow that to a job the maintainer has just started and approved, for the
convenience of releasing without a particular Mac. The same script still runs by hand from `main`
on that Mac, with the login keychain and a stored notarization profile, should the workflow be
unavailable.

The script refuses to go on at the first step that fails: a clean tree; in the workflow, a tag
naming the commit being built, and that commit on `main`; by hand, `main` equal to `origin/main`
and no tag yet; CI green on the commit, the certificate present; then the archive,
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

- A release is a tag, an approval, and the time of two notarizations.
- Users update by downloading the next image. Agents kept running survive it.
- The first release candidate is drafted by pushing a tag such as `v1.0.0-rc.1`; it is
  marked as a pre-release.

## Rejected alternatives

- **An unsigned build with instructions to bypass Gatekeeper.** Teaches users to disable a
  protection, and leaves A6 open.
- **Signing on the maintainer's Mac only.** The safest place for the key, and the first decision of
  this record; replaced by the protected environment for the convenience of releasing from
  anywhere.
- **A release, or a nightly, at every push to `main`.** Two notarizations per merge, and a list of
  releases nobody decided.
- **A Homebrew cask.** Worth considering after the V1; it would download the same notarized image.
