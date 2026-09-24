# Operations: recovering, and what Vibe Manager does not do

Linked from Help → Troubleshooting. Each section starts from a symptom. When none fits, Help →
Export Diagnostics… produces a file to attach to an issue: the sheet shows all of it before it is
saved, and it holds no prompt, note, session name, folder name or terminal content
([ADR 0020](architecture/0020-diagnostics.md)).

## Where things are

| What | Where |
|---|---|
| Sessions, and the backup of the previous version | `~/Library/Application Support/com.hadrienl.VibeManager/sessions.json`, `sessions.backup.json` |
| Damaged stores kept for inspection | `…/com.hadrienl.VibeManager/sessions.corrupt-<uuid>.json` |
| What the last run was running | `…/com.hadrienl.VibeManager/runtime.json` |
| Notes | `…/com.hadrienl.VibeManager/Notes/<session>.txt` |
| Prompt templates | `…/com.hadrienl.VibeManager/templates.json` |
| Usage figures | `…/com.hadrienl.VibeManager/Usage/` |
| Diagnostics log | `~/Library/Logs/Vibe Manager/app.jsonl`, `host.jsonl`, and the salt of the session pseudonyms, `.salt` |
| Preferences | `~/Library/Preferences/com.hadrienl.VibeManager.plist` |
| The terminal host's socket and lock | `$TMPDIR/vibe-manager/<hash of the data folder>/` |

Every file is readable only by you (`0600`), every folder `0700`; the application brings its folders
back to that at launch if a backup restored them otherwise.

## Recovering

### "Sessions unavailable", or a banner saying the store is damaged

The store could not be read. If a valid backup exists, **Restore Backup** puts back the previous
version: the damaged file is kept beside it as `sessions.corrupt-<uuid>.json`, never deleted, and a
store written by a newer version of the application is never rewound
([ADR 0002](architecture/0002-session-persistence.md)). Without a backup, quit, move
`sessions.json` aside, and relaunch: the application starts empty, and the moved file is what an
issue should carry — by hand, because it holds your sessions.

### The application believes another copy is running, or offers to restore on every launch

`runtime.json` describes the last run. Quit, delete it, relaunch: the sessions stay in the store,
closed, and Restart puts each back to work. Nothing else reads that file.

### Agents kept running cannot be reattached ("could not reattach")

The terminal host is alive and holds them, but will not serve this copy: another copy is attached,
or it did not answer in time. **Try Again** in the banner asks once more. If it never answers:

```sh
pkill -f -- 'Vibe Manager --terminal-host'
```

This stops the host, and **the agents it kept stop with it**: their conversations are resumed at the
next launch where the agent supports it, and what they were in the middle of is lost.

### Full Disk Access, or a folder permission, is asked for again and again

macOS ties permissions to the application's signature. A release is signed with a Developer ID and
keeps them across updates. A development build signed ad hoc gets a new identity at every build:
put a team in `Configuration/Local.xcconfig` (see the README). To start over from nothing:

```sh
tccutil reset SystemPolicyAllFiles com.hadrienl.VibeManager
```

### An agent is not found

Settings, or the New Session sheet, show why: not installed, not executable, too old, not signed
in. **Detect Again** after installing or signing in. When it lives somewhere the application does
not look — the login shell's `PATH` is asked as a last resort — set its path in Settings.

### Working on a copy that must not touch your sessions

```sh
VIBE_DATA_DIRECTORY=/tmp/vibe-copy open -n "/Applications/Vibe Manager.app"
```

The copy has its own store, runtime document, notes, logs (`<folder>/Logs`), preferences and
terminal host. `VIBE_ENABLE_MOCK_AGENT=1` adds an agent that needs no account, `only` offers it
alone.

### Something else

Help → Export Diagnostics…, then open an issue with the file. `defaults write
com.hadrienl.VibeManager DiagnosticsVerbose -bool YES` adds debug events to the log — made of the
same types as the others: verbose is not indiscreet — and turns on the main-thread hang detector.

## Uninstalling completely

Quit the application, choosing Stop All if it asks, then:

```sh
rm -rf "/Applications/Vibe Manager.app" \
  ~/Library/Application\ Support/com.hadrienl.VibeManager \
  ~/Library/Logs/Vibe\ Manager \
  ~/Library/Saved\ Application\ State/com.hadrienl.VibeManager.savedState \
  "$TMPDIR/vibe-manager"
defaults delete com.hadrienl.VibeManager
defaults delete com.hadrienl.VibeManager.isolated 2>/dev/null
tccutil reset All com.hadrienl.VibeManager
```

The agents' own files — `~/.claude`, `~/.codex` — belong to them and are left alone.

## Known limits

- **VoiceOver reads the terminal's visible screen**, and the last lines on demand (⌃⌥⌘O), not a
  full-screen program element by element ([accessibility](accessibility.md)).
- **A restart or a logout stops the agents.** Keep Running survives quitting the application, not
  the session of the Mac.
- **The application and its terminal host killed together** (`killall -9`) leave the agents
  running until the next launch, which finds and stops them. It is the one case where a process
  outlives both; a host that dies alone has its agents stopped at once by the application.
- **The initial prompt is visible to `ps`** for your own user, as an argument of the agent: passing
  it otherwise would change how the CLIs run. A process of your user can read the store and the
  terminals anyway (security review A5).
- **A process of your own user can read the terminals** (`/dev/ttys*`), as with any terminal.
- **An agent taken back after a relaunch is no longer observed**: a resume identifier it had not
  written before the quit is not captured.
- **No downgrade.** A store written by a newer version is refused by an older one, never rewound.
- **No automatic update.** Updates are downloaded from GitHub Releases; agents kept running survive
  the update ([ADR 0021](architecture/0021-distribution.md)).
- **macOS 14 or later.**
- **No App Sandbox**: an agent needs to run tools and read the folders it is given
  ([ADR 0001](architecture/0001-project-foundation.md)).
- **The agents' permissions are theirs.** What Claude Code or Codex may do inside a session is
  their own configuration; Vibe Manager neither widens nor narrows it.
- **Each terminal keeps 5,000 lines** on screen and in its history (about 17 MB for a full one of
  120 columns): many long-running sessions add up.
