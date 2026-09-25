# Security review

What the application runs, with what, for how long, and how it stops it. Written for #19 and kept up
to date: a change that adds a way to start a process, reads a new secret-bearing file or widens an
environment updates this document in the same pull request.

`ProcessLaunchInventoryTests` enforces the first table. It fails when `Process(`, `posix_spawn(`,
`system(`, `popen(`, `fork(` or `exec*(` appears in a production source other than the three
launchers listed below.

## Process launch inventory

| Launcher | What it starts | argv | Environment | Timeout | Stopped by |
|---|---|---|---|---|---|
| `PseudoTerminal` (`VibeTerminal`) | An agent, or a login shell, in a terminal | `TerminalSpec.arguments`, an array; the provider puts `--` before the prompt | `TerminalSpec.environment`: `AgentEnvironmentPolicy` allowlist plus what the provider declares; never an `*_API_KEY` | None: a session lasts as long as the user wants it | `SIGTERM` to the session's group, 3 s, then `SIGKILL` to the group. `ChildProcessGroupGuard` kills the group from `atexit`. |
| `ExecutableTerminalHostLauncher` (`TerminalHost.swift`) | The terminal host: the application's own binary with `--terminal-host <directory>` | Fixed | `HOME USER LOGNAME TMPDIR PATH LANG SHELL` | None: the host leaves by itself when it has no session and no client for 5 s | `stopAll`, then `goodbye(keepRunning: false)`. A client that vanishes without `goodbye` makes the host stop everything (ADR 0017). |
| `BoundedProcess` (`VibeProcess`) | Everything else, below | An array | Explicit, required by the type | Required by the type | `SIGTERM` to the group, a grace period, then `SIGKILL` to the group; whatever the command left in its group once it has exited is stopped the same way |

Every `BoundedProcess` command runs with `POSIX_SPAWN_SETPGROUP` (a group of its own, no new
session: these commands have no terminal and must not acquire one), `POSIX_SPAWN_CLOEXEC_DEFAULT`
(no descriptor but the three it is given), default signal dispositions and an empty signal mask,
standard input on `/dev/null`, and at most 1 MiB kept from each output stream unless the caller
asks for another bound. It is registered with `ChildProcessGroupGuard` while it may run.

| Caller of `BoundedProcess` | Command | Environment | Timeout | Output kept |
|---|---|---|---|---|
| `AgentAvailabilityProbe`, through `SystemProcessProbe` | `<agent> --version` | `AgentEnvironmentPolicy` | 5 s, retried once at 10 s | 64 KiB |
| `AgentAvailabilityProbe`, through `SystemProcessProbe` | `claude auth status --json`, `codex login status` | `AgentEnvironmentPolicy` | 5 s, retried once at 10 s | 64 KiB |
| `FileSystemExecutableLocator`, through `SystemProcessProbe` | `$SHELL -l -c "command -v -- '<binary>'"`, the binary name single quoted, and the only command ever interpolated into shell text | `AgentEnvironmentPolicy` | 3 s, retried once at 10 s | 64 KiB |
| `ProcessGitCommandRunner` | `git -c core.fsmonitor=false -c core.hooksPath=/dev/null <verb> …`, verbs: `status`, `rev-parse`, `symbolic-ref`, `reflog`, `for-each-ref`, `merge-base`, `rev-list`, `diff --no-ext-diff --no-textconv` | `HOME PATH USER LOGNAME TMPDIR SSH_AUTH_SOCK`, English locale, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `GIT_PAGER=cat` | 30 s for the inspector, 120 s otherwise | 64 MiB; beyond that the command is reported as failed, never parsed cut |
| `GitExecutable` | `/usr/bin/xcode-select -p` | As `git` | 5 s | 4 KiB |

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
