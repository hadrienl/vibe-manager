# Release checklist

Reproducible, in two parts: what the scripts check, and what a person has to. A release stays a
draft on GitHub Releases until every box of both is ticked; the draft's notes get the filled-in
copy of this list, figures included.

Copy this into the draft, then tick as you go.

## Before

- [ ] `main` is where the release is cut from, pushed, and CI is green on its last commit.
- [ ] The `ui-smoke` workflow is green on that commit (Actions → CI → Run workflow, if it has not
      run since).
- [ ] The version follows the previous one: `1.2.3`, or `1.2.3-rc.1` for a release candidate.
- [ ] A final version comes after a release candidate of the same commit whose Release workflow
      went to the end: CI builds in Release but signs nothing, so signing, notarization and the
      disk image are only ever tried by that workflow. A candidate that fails is fixed on `main`
      and followed by `rc.2`; its draft is deleted.
- [ ] The `release` environment holds `DEVELOPER_ID_CERTIFICATE_P12`,
      `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `NOTARY_API_KEY_P8`, `NOTARY_API_KEY_ID`,
      `NOTARY_API_ISSUER_ID`, and the variable `VIBE_TEAM_ID`; it requires a reviewer and only
      accepts `v*` tags.

## Automatic

- [ ] `git tag v<version> && git push origin v<version>`, then the Release workflow approved and run
      to the end (by hand instead: `Scripts/release.sh <version>` from `main`, before tagging). It
      checks, and stops at the first failure:
  - a clean tree, the tag on the commit being built and that commit on `main`, CI green on it;
  - a Developer ID Application certificate of the team;
  - the archive, built with `MARKETING_VERSION=<version>` and
    `CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)`, nothing written to the repository;
  - `codesign --verify --deep --strict`, no entitlement at all, the hardened runtime, a designated
    requirement naming the team (security review A6), the bundle identifier and version;
  - `mock-agent.sh` sealed in the bundle, no `Local.xcconfig`;
  - the application notarized and stapled, Gatekeeper accepting it;
  - the disk image built by `hdiutil`, signed, notarized, stapled, accepted by Gatekeeper;
  - the SHA-256 of the image, and a **draft** release with both files.
- [ ] `Scripts/clean-install-check.sh VibeManager-<version>.dmg`, on the image downloaded from the
      draft, passed:
      Gatekeeper and staples, installation in a folder of its own, TCC reset for the bundle, the
      interface smoke test against the installed binary, and its terminal host refusing an ad hoc
      binary that carries the application's identifier.
- [ ] `VIBE_PERFORMANCE=1 VIBE_PERFORMANCE_MINUTES=10 swift test --package-path
      Packages/VibeManagerKit --filter "PerformanceBudgetTests|ScrollbackMemoryTests"` passed, and
      its `PERF` lines are pasted here:

      ```
      PERF echo …
      PERF soak …
      PERF idle CPU …
      PERF launch …
      Scrollback of 3 × 5,000 lines …
      ```

- [ ] The canary scenario passed (it runs with every `swift test`: `CanaryScenarioTests`).

## Manual

- [ ] **A fresh macOS 14** virtual machine (UTM), never used for development: open the image,
      drag the application to Applications, open it. No Gatekeeper warning beyond the usual first
      launch question; the Full Disk Access step shows once; a session with the mock agent
      (`VIBE_ENABLE_MOCK_AGENT=1` from Terminal) runs.
- [ ] **VoiceOver and the keyboard**, with VoiceOver and Full Keyboard Access on: every action of
      [accessibility](accessibility.md) — create, select, close, restart, archive, switch agent,
      write a note, quit leaving the agents running, export a diagnostic — done without the pointer,
      and heard. Accessibility Inspector shows no warning on the main window, the New Session
      sheet, Settings and the export sheet. Increase Contrast and Reduce Transparency: the status
      badges are still told apart.
- [ ] **Three real sessions** — Claude Code and Codex, one of them on a real task — for fifteen
      minutes: output keeps up, typing never lags, the Git inspector follows the changes, notes are
      kept.
- [ ] **Memory**, during those fifteen minutes: `footprint "Vibe Manager"` under 400 MB for the
      application and under 60 MB for the terminal host
      (`footprint $(pgrep -f -- '--terminal-host')`); `leaks "Vibe Manager"` and `leaks` on the
      host report nothing the application owns. Idle CPU with the application in the background
      under 1 %, host included (Activity Monitor, 60 s). The transcript probes of Claude Code and
      Codex poll every 500 ms: if idle CPU is over budget with them, they move to file events
      before the release.
- [ ] **Update with agents kept running**: with version N installed and a session running, quit
      with Keep Running, install N+1 over it, open it: the session is taken back, running, its
      history on screen.
- [ ] **What TCC attributes to the terminal host** (ADR 0017 left this to measure). Grant Full
      Disk Access, start an agent in a session, quit with Keep Running, then have the agent read
      `~/Documents` while watching:

      ```sh
      log stream --predicate 'subsystem == "com.apple.TCC"' --info
      ```

      The access must be attributed to Vibe Manager, and granted. Revoke Full Disk Access and
      repeat: it must be refused, attributed to Vibe Manager. **Blocking**: if the chain names
      anything else, the release waits for the fallback of ADR 0017 (a minimal helper `.app` in
      `Contents/Library/`). Whatever the outcome, the quit setting stays **Ask** by default: Keep
      Running is never chosen for the user.
- [ ] **Diagnostics**: Help → Export Diagnostics… shows the whole file, saves it, and the archive
      opens; nothing in it names a session, a folder or a prompt.
- [ ] **Troubleshooting**: Help → Troubleshooting opens [operations](operations.md), and every
      recovery in it still matches the application.

## Publishing

- [ ] The draft's notes: what changed, this list filled in, the SHA-256.
- [ ] Publish the draft.
