# Security review

What the application runs, with what, for how long, and how it stops it. Written for #19 and kept up
to date: a change that adds a way to start a process, reads a new secret-bearing file or widens an
environment updates this document in the same pull request.

`ProcessLaunchInventoryTests` enforces the first table. It fails when `Process(`, `posix_spawn(`,
`system(`, `popen(`, `fork(` or `exec*(` appears in a production source other than the four
launchers listed below, and the `execv` of `ControllingTerminal`, which only turns a process one
of them started into the shell it was started for.

## Process launch inventory

| Launcher | What it starts | argv | Environment | Timeout | Stopped by |
|---|---|---|---|---|---|
| `PseudoTerminal` (`VibeTerminal`) | An agent, or a login shell, in a terminal | `TerminalSpec.arguments`, an array; the provider puts `--` before the prompt | `TerminalSpec.environment`: `AgentEnvironmentPolicy` allowlist plus what the provider declares; never an `*_API_KEY` | None: a session lasts as long as the user wants it | `SIGTERM` to the session's group, 3 s, then `SIGKILL` to the group. A side terminal (#43) is hung up on first — `SIGHUP` to its shell and to every group whose controlling terminal it is (`KERN_PROC_TTY`), 1 s — and those groups are swept with the shell's. `ChildProcessGroupGuard` kills the group from `atexit`. |
| `ControllingTerminal` (`VibeTerminal`) | Not a launch: the application's own binary, started by `PseudoTerminal` with `--terminal-exec <path> <argv0> <arguments…>` for a side terminal's shell, takes its terminal with `TIOCSCTTY` and `execv`s the shell in the same process (ADR 0030) | The shell's, passed through unchanged | The shell's, from `posix_spawn` | As the shell | As the shell: it is the shell once `execv` returns; a failed `execv` exits 127 |
| `ExecutableTerminalHostLauncher` (`TerminalHost.swift`) | The terminal host: the application's own binary with `--terminal-host <directory>` | Fixed | `HOME USER LOGNAME TMPDIR PATH LANG SHELL` | None: the host leaves by itself when it has no session and no client for 5 s | `stopAll`, then `goodbye(keepRunning: false)`. A client that vanishes without `goodbye` makes the host stop everything (ADR 0017). |
| `SpawnedFullDiskAccessProbe` (`CurrentFullDiskAccess.swift`) | The application's own binary with `--probe-full-disk-access`, answering for itself to TCC: it opens the TCC database's path, reads nothing, and exits `0` or `1` (#76) | Fixed | `HOME USER LOGNAME TMPDIR PATH` | 10 s, then `SIGKILL` | Exits by itself at once; reaped with `waitpid` |
| Sparkle (`VibeUpdates`, a binary framework) | When an update is installed (#92, ADR 0033): its `Autoupdate` helper and `Updater.app`, from the framework in the bundle, which replace the bundle once the application has quit and relaunch it | Sparkle's | Sparkle's | None: they end once the bundle is replaced | Themselves. Nothing is started before the user chose Install and Relaunch, or quit with an update downloaded |
| `BoundedProcess` (`VibeProcess`) | Everything else, below | An array | Explicit, required by the type | Required by the type | `SIGTERM` to the group, a grace period, then `SIGKILL` to the group; whatever the command left in its group once it has exited is stopped the same way |

Every `BoundedProcess` command runs with `POSIX_SPAWN_SETPGROUP` (a group of its own, no new
session: these commands have no terminal and must not acquire one), `POSIX_SPAWN_CLOEXEC_DEFAULT`
(no descriptor but the three it is given), default signal dispositions and an empty signal mask,
standard input on `/dev/null` unless the caller hands it one, and at most 1 MiB kept from each output stream unless the caller
asks for another bound. It is registered with `ChildProcessGroupGuard` while it may run.

| Caller of `BoundedProcess` | Command | Environment | Timeout | Output kept |
|---|---|---|---|---|
| `AgentAvailabilityProbe`, through `SystemProcessProbe` | `<agent> --version` | `AgentEnvironmentPolicy` | 5 s, retried once at 10 s | 64 KiB |
| `AgentAvailabilityProbe`, through `SystemProcessProbe` | `claude auth status --json`, `codex login status` | `AgentEnvironmentPolicy` | 5 s, retried once at 10 s | 64 KiB |
| `FileSystemExecutableLocator`, through `SystemProcessProbe` | `$SHELL -l -c "command -v -- '<binary>'"`, the binary name single quoted, and the only command ever interpolated into shell text | `AgentEnvironmentPolicy` | 3 s, retried once at 10 s | 64 KiB |
| `ProcessGitCommandRunner` | `git -c core.fsmonitor=false -c core.hooksPath=/dev/null <verb> …`, verbs: `status`, `rev-parse`, `symbolic-ref`, `reflog`, `for-each-ref`, `merge-base`, `rev-list`, `diff --no-ext-diff --no-textconv` | `HOME PATH USER LOGNAME TMPDIR SSH_AUTH_SOCK`, English locale, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `GIT_PAGER=cat` | 30 s for the inspector, 120 s otherwise | 64 MiB; beyond that the command is reported as failed, never parsed cut |
| `GitExecutable` | `/usr/bin/xcode-select -p` | As `git` | 5 s | 4 KiB |
| `CodexAppServerProcess` (#45) | `codex app-server -c hooks.<Event>=[…]…`, fed `initialize` and one call — `hooks/list`, or `config/batchWrite` of the approval of our hooks alone — on its standard input, kept open until the answer comes | The agent's launch plan: `AgentEnvironmentPolicy`, `CODEX_HOME` included | 5 s | 1 MiB |

`Process` is not used anywhere in production code. It gives no control over the process group,
passes every descriptor the application has not marked close-on-exec, and only ever signals the one
pid, so a `git` that started a helper or a login shell whose profile started one left it running.

## What was checked

- **No shell with user data.** Arguments are arrays from the provider to `posix_spawn`. The one
  shell command line is the login shell lookup above, whose only parameter is the binary name of a
  provider, single quoted.
- **The prompt goes after `--`**, so a prompt that starts with `-` is never read as an option.
  Model identifiers are validated against a pattern before they reach argv.
- **Environments are allowlists.** The application's environment is never passed on whole. No
  variable ending in `_API_KEY`, `_TOKEN` or `_SECRET` is forwarded unless a provider declares it,
  and neither built-in provider does. Both declare the proxy and certificate variables
  (`HTTPS_PROXY`…), which may carry credentials: they reach the agent and its probes, and nothing
  else — the diagnostics log and export never read an environment (the canary scenario puts one
  in `HTTPS_PROXY` to prove it).
- **Files are owner only.** The session store, its backup, the quarantined `*.corrupt-*.json`
  copies, `runtime.json`, notes, templates, usage and logs are written `0600`, through a temporary
  file and a rename; their folders are created `0700`.
- **The terminal host's peer is verified** by the kernel's audit token against the application's
  designated requirement (ADR 0017), and its socket lives in a `0700` folder of the per-user
  temporary directory.
- **`SO_NOSIGPIPE`** on the host socket, and `SIGPIPE` ignored in the host.

## Findings and decisions

| # | Finding | Risk | Decision |
|---|---|---|---|
| A1 | `git status` ran without `core.fsmonitor=false` | A repository the user only **displays** in the inspector could run a command from its own `.git/config`: the usual way a hostile repository runs code in whoever looks at it | **Fixed.** Every command is prefixed with `-c core.fsmonitor=false -c core.hooksPath=/dev/null`, and `diff` gets `--no-ext-diff --no-textconv`. The user's global configuration is still read for the rest (`safe.directory`, identity). `HostileRepositoryTests` proves a repository with both set runs nothing. |
| A2 | Probes, `git` and `xcode-select` were started with `Process()`: no group, no guard, only the pid killed on timeout | A login shell whose profile starts a daemon, or a `git` that starts a helper, left grandchildren behind | **Fixed** by `BoundedProcess`. |
| A3 | `xcode-select -p` was waited for **without a timeout**, with the whole inherited environment | The application could hang when looking for `git` | **Fixed**: `BoundedProcess`, 5 s, environment allowlist. |
| A4 | A data folder that **already existed** was never brought back to `0700` | A store created by an early build, or restored from a Time Machine backup, could be readable by the other accounts of the Mac | **Fixed**: at launch, `DataDirectoryPermissions` tightens the data folder, `Notes/`, `Usage/` and `Logs/`, and the files directly inside them. The quarantined `*.corrupt-*.json` copies were already written `0600`; a test now proves it for a damaged store that was `0644`. |
| A5 | The initial prompt is passed in argv | Visible to `ps` for **the same user** | **Accepted and documented.** Passing it on standard input would change the CLI's mode (non interactive), and a process of the same user can already read `sessions.json` and `/dev/ttys*` (ADR 0017). See [operations](operations.md#known-limits). |
| A6 | Without a Team ID, the host's peer requirement is the bundle identifier alone | An ad hoc binary of the same user carrying that identifier could talk to the host | **Acceptable in development** (ADR 0017), **refused for a release**: `Scripts/release.sh` stops if `codesign -d -r-` does not name the team (`certificate leaf[subject.OU]`), and `Scripts/clean-install-check.sh` proves the notarized host refuses a binary signed ad hoc under the application's identifier. |
| A7 | The host inherited launchd's soft limit of 256 descriptors | About twenty sessions plus their probes reached `EMFILE`, in the middle of serving the others | **Fixed**: the host raises its soft limit to `min(hard, 4096)` when it starts, and refuses a 65th running session with `TerminalError.tooManySessions`. |
| A8 | `mock-agent.sh` ships in the Release bundle | None: it is sealed by the signature and only enabled by `VIBE_ENABLE_MOCK_AGENT`, which only the user can set | **Kept**: it is what lets the smoke test run against the notarized build. `release.sh` checks it is there and sealed. |
| A9 | A session stopped on purpose only had its group signalled while its leader ran: an agent that exited on `SIGTERM` left a child that ignores it in the group | An orphan with no terminal and nobody to see it | **Fixed**: once the leader has exited, whatever is left in its group is killed (`PTYTerminalSession.sweepGroup`). |
| A10 | A terminal host killed while the application runs closed its terminals with a hang-up, which an agent may ignore | Agents running unseen until the next launch | **Fixed**: the application stops every group the host ran for it at once, after checking each is still the one it recorded (ADR 0011's rule), and the session ends saying the host stopped. |
| A11 | The web view's channel (#69) lets an agent click, type and run JavaScript in pages the user may be signed in to | An agent acting as the user on a forge, a mailbox, a bank | **Decided in ADR 0023**: acting is free only on this Mac (`localhost`, loopback, `file:`), asked everywhere else, and each "Always Allow" is per site, listed and removable in Settings. A connection is accepted only from a process that descends from a session's agent (pid and start time checked at every link), for that session alone; no secret is put in an agent's environment or command line. `BrowserPolicyTests`, `BrowserChannelAuthorizerTests` and `BrowserChannelTests` (a real child process accepted, a stranger refused) prove it. |
| A12 | Claude Code is started with `--allowedTools mcp__vibe-browser` | Claude no longer asks before a web view tool | **Accepted**: Vibe Manager asks before anything is done as the user, and a second question on the same call adds nothing. The user's other tools keep their own rules. |
| A14 | The application replaces itself with what a feed on the Internet offers (#92) | A compromised feed, Pages site or GitHub account delivering a malicious build to every copy | **Decided in ADR 0033**: an archive is installed only if its EdDSA signature verifies with the key the application carries **and** the application inside is signed with the same Developer ID — checked before anything is extracted. The private key is a secret of the protected `release` environment and a copy offline, never in the repository nor in the feed's workflow, which holds no secret. Feed and archives over HTTPS only. `release.sh` checks each archive against the application's own key, and the designated requirement against `Configuration/DesignatedRequirement.txt`. Copies built from source, or isolated, never update themselves. Rotation of a lost key is in [operations](operations.md#rotating-the-update-key). |
| A13 | A new session's ticket addresses are loaded in its web view, where the user is signed in, to read their titles (#89) | A crafted address loading a page on the user's behalf; another page's title passed off as the ticket's | **Decided in ADR 0031**: only an address an enabled resolver's pattern recognises is loaded, the way a click would load it; nothing is ever handed to a shell or a command. A title is read only once the page's own address is recognised again by the same resolver as the same ticket, with a 2xx answer: a sign-in page or a redirection to another ticket gives none. No token is stored: the session is the web view's. `TicketPageReadingTests` prove the redirections, and `TicketTitlesTests` that nothing is read when the feature is off. |
| A15 | An agent — misled by a page it read, or a script in its terminal — could read any site the user is signed in to in the web view, open it out of sight, and carry it elsewhere by navigating; a script could add an "Always Allow" with `defaults write` (#239) | A private ticket, repository or mailbox read and sent to another site without the user ever being asked | **Fixed, ADR 0023**: reading a site away from this Mac is asked once per site and session, titles are withheld until then, such a page never loads in the background, and the sites always allowed are an item of the login keychain, the former list in the user defaults erased. Every descendant of the agent is still accepted on the channel, by choice. `BrowserPolicyTests`, `BrowserWorkspaceToolsTests` (a question per session, refused then allowed) and `BrowserGrantStoreTests` (a site written with `defaults write` is not allowed) prove it. |

## Residual risks

- **Git filter drivers.** A `.gitattributes` naming a `filter` whose `clean` command is defined in
  the repository's `.git/config` runs that command when `git status` hashes a changed file. There is
  no option that disables every driver without naming it. `.git/config` is not transported by
  `git clone`, so this needs a repository delivered as a folder or an archive; opening one in any
  Git client runs the same command.
- **What a same-user process can do.** Read the store, the terminals and argv; connect to nothing
  it cannot already reach. The application does not defend against its own user.
- **Agents' own permissions.** What Claude Code or Codex are allowed to do inside a session is their
  configuration, not the application's.
- **What an agent reads in the web view, once allowed.** Since #239, reading a site away from this
  Mac is asked once per site and session, and titles are withheld until then. Once the user allows
  a site, the session's agent — or a script in its terminal, which speaks for it — can read it for
  the rest of the session and, misled by a page, carry what it read to another site by navigating
  there. The question says so; outgoing navigations are not filtered (ADR 0023).
- **"Always Allow" in the keychain.** Since #239 the sites are an item of the login keychain that
  only the application reads without asking; the former list in the user defaults is erased and
  ignored. A program of the user's can still ask macOS for the item, and the user can say yes.
- **The history of side terminals is on disk** (#43, ADR 0030). What a side terminal showed —
  possibly a token a command printed — is written to `Terminals/<session>/*.scrollback`, `0600` in
  `0700` folders excluded from backups, bounded to 4 MiB per terminal, never read by the
  diagnostics beyond its total size, and erased when the setting is turned off. A process of your
  user can read it, as it can read the terminal itself. The agent's terminal is never written.
- **The web view's trace and tabs.** `Browser/*.json` are `0600` in a `0700` folder; a process of
  the same user can read or rewrite them. A typed value is kept cut short, and never for a password,
  card or one-time-code field.
