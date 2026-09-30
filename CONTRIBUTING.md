# Contributing to Vibe Manager

Thanks for taking the time to help. Bug reports, ideas, translations and pull requests are all
welcome. By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting a bug or asking for a feature

Open an [issue](https://github.com/hadrienl/vibe-manager/issues/new/choose) with the matching
template. For a bug, the version (**Vibe Manager › About**), the macOS version, the agent involved
and the steps to reproduce it are what make it fixable. **Help › Report an Issue…** in the
application opens the same page.

A security problem is never reported in a public issue: see the [security policy](.github/SECURITY.md).

## Before writing code

For anything larger than a small fix, open or comment an issue first so the approach can be agreed
on before you spend time on it. The design decisions live in
[`docs/architecture/`](docs/architecture/), one numbered record per subject; read the ones your
change touches. A change that reverses one of them updates its record, or adds a new one, in the
same pull request.

## Setting up

Requirements and first steps are in the [README](README.md#requirements). In short:

1. Copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig` and set your own
   `DEVELOPMENT_TEAM`. Without it the build is signed ad hoc and macOS asks again for every privacy
   permission after each build.
2. Open `VibeManager.xcodeproj`, select the `VibeManager` scheme and run.

## Checks

Run what CI runs before pushing:

```sh
Scripts/ci.sh
```

It lints the formatting (`xcrun swift-format lint`, configured by `.swift-format`), checks the
translations, runs the package tests and builds the application. To iterate faster:

```sh
swift test --package-path Packages/VibeManagerKit --filter SomeTests
```

A few rules the review will look for:

- **Tests.** A fix comes with the test that would have caught it; a feature with tests of its
  behaviour. Tests wait for a state, never for a fixed delay, and never put a window on screen.
- **Strings.** Every text a user can read goes through the target's `Localizable.xcstrings` and is
  translated in every language the application ships. See
  [`docs/localization.md`](docs/localization.md).
- **Accessibility.** Controls have labels and keyboard access. See
  [`docs/accessibility.md`](docs/accessibility.md).
- **Processes.** A new way to start a process, a new secret-bearing file or a wider environment
  updates [`docs/security-review.md`](docs/security-review.md).

## Pull requests

- Branch from `main`, one subject per pull request.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`,
  `perf:`, `test:`, `docs:`, `chore:`, with the issue number when there is one, e.g.
  `fix: keep the toolbar buttons on the right (#256)`.
- Fill in the pull request template: what changes, why, and how it was tested. For a visual
  change, add a screenshot in light and dark mode.
- CI must pass. Tests that time out on the shared runner are sometimes flaky: rerun once before
  investigating.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
