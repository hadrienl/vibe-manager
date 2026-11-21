# 0014 — The Git context of a session, one repository at a time, beside its notes

- Status: accepted
- Date: 2026-09-23
- Issue: [#14](https://github.com/hadrienl/vibe-manager/issues/14), extended by
  [#56](https://github.com/hadrienl/vibe-manager/issues/56)

## Context

ADR 0012 finds the repositories a session works in and what its agent did to their branches;
ADR 0013 keeps each of them live — every changed file, staged or not, attributed or not, the
distance from upstream, an operation left half done, and a failure beside the last state that was
true. The inspector showed a sentence per repository, grouped by branch.

This decision shows all of it: one group per repository, its changed files, and a way from a file
to the disk. It adds no source of truth: everything drawn is what the branch report and the monitor
already publish.

## Decisions

### Two panes: Git above, the session below

The inspector is split in two, each pane scrolling on its own: **Git** above, the session's
**Notes**, agent and initial prompt below. A single list holding five thousand files would push
the notes out of reach; two panes keep them a glance away, and the editor of #16 will take their
place without moving anything.

Since ADR 0023 (#36), the top pane switches between the session's **Activity** and **Git**, by a
segmented control kept in `WorkspaceLayout.inspectorTopTab`; everything below still holds for the
Git tab.

- The divider is the application's own, not a `VSplitView`, whose position cannot be set or read
  back. Its share goes to `WorkspaceLayout.inspectorSplit` (0.25–0.85, 0.6 by default), written
  once a drag ends. A layout stored before it existed decodes with the default.
- Neither pane can be dragged under 120 points. The divider is adjustable by VoiceOver, in steps of
  5 %.
- The section that listed the attached folders is gone: each is a repository group already. A
  folder that is not a repository itself — a folder of repositories, typically — is said to be so.

### One group per repository

A group is one line of the branch report, in its order; a worktree the agent made for itself is a
repository in its own right (ADR 0013) and has its own group, named after its clone. The header
says the name, the branch — whole, on as many lines as it takes; "detached at 1a2b3c4";
"main, no commits yet" — the report's pills, the distance from upstream (`↑2 ↓1`, and in full in
its tooltip, which says nothing was fetched), an operation in progress, how many changes, the
counts in words from ADR 0013, and the sessions it is shared with.

Under it, up to five lists, absent when empty: **Conflicts** first, since they are what stops the
agent, then **Staged**, **Unstaged** and **Untracked**, each in Git's order. A file staged and
changed again since (`MM`) is in both lists: what the commit will hold is not what is on disk.
**Committed** comes last (below).

A row is a status letter (`M A D R C T UU ?`) coloured by the kind of change — the letter carries
the meaning, the colour only repeats it — then the file's name, and its folder beneath it,
truncated in the middle. A rename shows `new ← old` and its similarity. A file the session's
transcript does not name carries a discreet `?`, whose tooltip says what that means and what it
does not: a shell command, another session or the user may have changed it. Nothing is attributed
to another session.

Names are shown in NFC and keyed as Git wrote them: a name macOS stored decomposed reads like one
typed, and still matches itself from one reading to the next.

### What the branch already committed

`git status` forgets a file the moment it is committed, and an agent commits at the end of nearly
every task: a finished session would show "No changes" beside a `+7`. A fifth list, **Committed**,
after the others, holds what the branch's commits changed — what a pull request of it would show:

```
git for-each-ref --format='%(refname)%00%(objectname)%00%(symref)' <base references>
git merge-base <base> HEAD
git rev-list --count <merge-base>..HEAD
git diff --name-status -z --find-renames <merge-base> HEAD
```

- The base is the first that exists of the branch `origin/HEAD` points to, `origin/main`,
  `origin/master`, `main`, `master`. Local references only: nothing is fetched. On `main` ahead of
  `origin/main`, the list is what is not pushed yet.
- No base, or no commit the base lacks: no list, and the summary says "No changes" as before.
  Otherwise a clean tree says "Working tree clean — 12 files committed since origin/main", and a
  dirty one adds the same to its counts. The count in the header stays the working tree's.
- The list is read with each `git status`, but the diff only when `HEAD` or the base moved: the
  reader keeps the last one per repository with the two revisions it was read between. A file saved
  costs one `for-each-ref`. A Git that fails — a diff past its 30 s, a shallow clone without the merge
  base — is not "nothing committed": the last list stays, and the next reading tries again.
- Its tooltip names the commits and the merge base. It is attributed like the others: a branch may
  carry commits from before the session, and those files carry the `?`. Five thousand files are
  kept, all counted; a list longer than 50 starts folded, and a group with committed files starts
  unfolded.
- A file selected when it is committed follows into Committed, like a file staged follows into
  Staged.

### Identity is what keeps expansion and selection

A group is identified by its repository's path, a list by the repository and its column, a row by
the repository, the column and the path — never by a position or a count. SwiftUI keeps the state
of what keeps its identity, the scroll position included, so a state published by the monitor
redraws only what moved.

`GitInspectorModel`, beside `AppModel`, keeps the screen state per session for the length of the
run, and nothing of it is persisted:

- A group is unfolded when it has changes or a failure to read about, folded when clean. Once the
  user folds or unfolds it, their choice wins: a repository folded by hand stays folded while its
  agent keeps writing.
- A list shows 200 rows, then **Show 200 More** and **Show All**, and remembers which was chosen.
  An untracked list longer than 50 starts folded: it is usually a folder `.gitignore` forgot.
- One row is selected at a time. When its file moves to another list — `git add` takes it from
  Unstaged to Staged — the selection follows the file, not the list, and that list is opened far
  enough to show it. When the file is gone, or folded out of sight, so is the selection.
- Coming back to a session finds it as it was left.

The presentation of a group is a pure function of the report's line and the monitor's state, cached
until either changes. The selection, the folding and the folder listings are observed apart, and a
group's view compares equal while what it draws does not change: an arrow key moving the selection
does not have every list compare its rows again. The attached folders that are no repository are
resolved on the disk once per report, never at a redraw. A test publishes
five thousand entries ten times and never holds the main actor for 50 ms.

### Untracked folders unfold on demand

An untracked folder is one entry (ADR 0013). Its files are read only when it is unfolded, and read
again only when its repository's state is published anew:

```
git --no-optional-locks status --porcelain=v2 -z --untracked-files=all -- ':(literal)<folder>/'
```

The pathspec is literal, so `[draft]*/` is that folder and not a pattern. The reading goes through
the monitor, under the same limit of two Git processes at once as `git status`. One reading per
folder at a time: whatever asks during it gets one more after it, and an answer older than the last
question is never shown. A thousand files are listed, the rest counted.

### A file, from the list to the disk

| Gesture | What happens |
|---|---|
| Return, double-click | Opens in the editor chosen in Settings; with none, reveals in the Finder. A folder — untracked, or a submodule — is always revealed |
| **Reveal in Finder**, ⌘⇧R | Selects the file — or, if it was deleted, the closest folder still there. ⌘⇧R only while the list has the focus: in the terminal it is the agent's |
| **Open in ‹editor›** | Offered when an editor is chosen; disabled for a deleted file or a folder |
| **Open with Default Application** | Whatever the settings chose; disabled for a deleted file or a folder |
| **Copy Path**, **Copy Relative Path** | Absolute, or relative to the repository |

- Revealing always works, with or without an editor: it is the floor the issue sets.
- **Settings → Git → Open changed files with**: "Finder (reveal only)" by default, the default
  application, the known editors installed on this Mac (a closed list — VS Code, Cursor, Zed,
  Xcode, Sublime Text, Nova, BBEdit, IntelliJ IDEA, WebStorm), or any other application chosen with
  **Other…**. It is stored as a bundle identifier, in the user defaults, behind the
  `FileOpeningPreferences` port. Nothing opens in an application the user did not choose.
- An editor uninstalled since: the file is revealed instead, and the pane says why.
- The path comes from Git, a process of its own: the file is the repository's root and the
  relative path, standardised, and refused if it would lead outside the root.
- The header of a group reveals the repository, opens it in the editor, or copies its path.

The application still never acts on Git (ADR 0012): no staging, discarding or committing.

### States

- **No repository**: said. **Report not read yet**: "Reading the repositories…", with a spinner,
  never a skeleton. **A repository read for the first time**: a spinner in its header, no list.
- **Reading again**: nothing moves — ADR 0013 publishes only what changed.
- **Clean**: folded, "No changes" — or, on a branch that committed, unfolded on its Committed
  list; every repository clean is said once, above the groups.
- **Failure**: in its group, the sentence, the suggestion, the command to copy with a **Copy**
  button, and the one action that helps — **Refresh**, **Reveal Parent Folder** for a repository
  gone, **Open Privacy Settings** for a refusal. The last list stays, dimmed, "as of 14:02". The
  age of a lock is said again as it grows.
- **Git missing everywhere**: one banner for all repositories, not one each.
- Never a dialog, never a banner over the window.

## Consequences

- `VibeDomain` and `VibeApplication` still know nothing of AppKit or SwiftUI: the editor choice is
  a value (`EditorChoice`) behind a port; revealing and opening go through `FileOpening`,
  implemented on `NSWorkspace` in `VibeUI` and replaced by a double in the tests.
- `RepositoryStatusReading` gains `untrackedFiles(in:atPath:limit:)`, and the monitor
  `untrackedFiles(in:of:)`.
- The branch grouping of ADR 0012 and the `modified` pill are gone.
- `WorkingTreeStatus` gains `committed` (`BranchCommits`), read by `GitStatusReader` with the
  status, and `RepositoryStatusState` its attributed files.

## Out of scope

Diffs and Quick Look; choosing the base by hand, and the commits themselves (messages, authors); a tree of folders, filtering and searching the list; Git actions; opening a
terminal in a repository (#43); keeping the folding across launches; a Git state per session in
the sidebar, which would mean watching sessions not on screen; the notes editor itself (#16).
