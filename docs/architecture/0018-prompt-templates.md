# 0018 — Prompt templates

- Status: accepted
- Date: 2026-09-24
- Issue: [#17](https://github.com/hadrienl/vibe-manager/issues/17)

## Context

Most sessions start from one of a few prompts: review this merge request, address the comments on
that one. Typing them again each time is slow, and copying them from somewhere else carries whatever
came with them. The session store has held a `PromptTemplateReference` since #2 without anything
filling it in.

A template is only useful if the user trusts what it sends. The prompt reaches the agent as one
argument, through `posix_spawn`, with no shell between them: there is nothing to quote, and quoting
would show in the prompt. What there is to get right is that the agent receives exactly the text
the sheet showed.

The user syntax, the storage and the exchange format are described for users in
[`docs/prompt-templates.md`](../prompt-templates.md).

## Decisions

### One rendering, used by the preview and the launch

`PromptTemplateFill` — a copy of the template and the values typed — renders the prompt, and the
same value is what the sheet previews, what `CreateSession` validates and plans, and what the
session stores. There is no second implementation that could drift. A value is inserted once and
never read again, so a value that holds `{{x}}` stays that text.

The fill holds a *copy* of the template, taken when it is picked. A template saved in the other
settings while the sheet is open is said there, with **Reload**; it is never swapped in under the
user, because the preview would then no longer describe what they were about to send.

### A starting point, never a link

The session stores the rendered prompt in `initialPrompt`, and the template's identifier, name and
revision in the existing `PromptTemplateReference`. Restart, the summaries of #10 and #15 and the
search all read `initialPrompt`, so none of them changed, and editing or deleting a
template later changes no session. The schema did not move: the reference was already stored.

**Edit as Text** turns the rendering into the free prompt and drops the reference. The reference
promises that this prompt is that template filled in; after a hand edit it is not.

### A syntax that is read without documentation

`{{name}}`, `{{name?}}` for an optional field, `\{{` for the braces themselves. Strict names — a
letter, then letters, digits, `-` and `_` — so that `{{payload.url}}` or `{{ items[0] }}`, which
prompts about code are full of, stay text rather than become fields. The editor underlines them so
they are not mistaken for fields either. Whether a field is required is written in the text,
where it is read; the editor's checkbox writes or removes the `?`.

`<url>` collided with HTML and generics, `${url}` with the shell. Labels, hints and multiline are
settings kept beside the text, so the text stays plain.

### What a prompt may carry

The NUL character ends a C string: `strdup` in the pseudo terminal would have cut the prompt there,
silently. `AgentLaunchValidation.promptDelivery` now refuses it, for every prompt — free, rendered
or a restart summary. Other control characters but tab and newline — an escape sequence pasted from
coloured output would drive the CLI's display — are removed from a rendering, where the preview
shows the result, and refused in a free prompt, where removing them would change what the user
typed without showing it. Summaries are left alone: they are built from the session and refusing
them would break a restart.

### Saved explicitly, unlike the notes

A template is saved with **Save**, and each save is a revision. A half-typed template must not be
offered in the sheet, and a revision per keystroke would make the number the session records
meaningless. Edits live in the library model for the length of the run, so closing the settings
loses nothing; leaving a changed template for another asks first, and so does quitting — Save,
Don't Save or Cancel, before anything is stopped.

### A store of its own, and a format of its own for exchange

`templates.json` sits beside `sessions.json` and is written the same way (ADR 0002): backup, unique
temporary file, `fsync`, rename, `0600`. Editing a template does not rewrite the sessions. A file
that cannot be read, or that a newer version wrote, makes the library read-only and is never
written over.

The export format is separate from the store, versioned on its own and documented for users: the
store may change between versions, a file someone was sent must not. It carries no revision and no
dates. An import is laid out before it is applied — new, identical, changed, skipped — and a changed
template is kept beside the existing one unless the user chooses **Replace**. A test imports the
example of the documentation, so the documentation cannot drift from the code. The files are plain
`.json`: declaring a document type of our own would need an `Info.plist` the project generates.

### Keeping part of a value, and trying it where it is written

`{{url|/pattern/}}` keeps what a regular expression finds in the field's value: the first match,
or its first group. It is the one computation a template allows, because the most common template
names its session after the number in a merge request's URL, and a separate field for that number
would ask for what the URL already says. The pattern lives in the text, like the `?`: nothing
changed in the store or the exchange format. It runs to the next unescaped `/`, so braces and bars
inside it are its own.

A value the pattern does not match gives nothing, and the sheet says so under the field. Refusing
it would stop a session over a URL that is merely shaped differently — the user sees what the name
will be before creating it. A pattern that does not compile keeps the template from being saved.

Each field of the editor has one **Try** value, shared with the preview: under it, every pattern
applied to that field shows what it keeps and where it is used. The sheet shows the same lines
under the field being filled.

### In the settings, not a window of their own

The templates are a tab of the settings, beside General: they are something configured once and
reached from time to time, which is what the settings are. Manage… in the sheet and File ▸ Manage
Prompt Templates… open the settings on that tab.

### No archive

A template the user no longer wants is deleted, after a confirmation, from the − button, ⌫ in the
list or its context menu. An archive between the two would only be a second place to look: a
session never depends on its template, so deleting one loses nothing but the template itself.

### Examples offered, never installed

The two examples have fixed identifiers. **Add Examples** adds the missing ones; nothing else ever
does, so one the user deleted does not come back.

### Prompt areas grow with their text

Every area where a prompt is written — the free prompt, a multiline field, a template's text — is a
`PromptTextEditor`: an `NSTextView` whose height follows the lines on screen, wrapped lines
included, from a minimum up to ten lines, then scrolls. `TextEditor` cannot say how tall its content
is; `TextField(axis: .vertical)` grows but submits on Return. Return goes to the line, ⌘↩ submits
the sheet or saves the template, and nothing is autocorrected: `--force` must not become `—force`.

## Out of scope

Automatic variables (`{{branch}}`, `{{date}}`), conditions and loops, remembered values, templates
that choose an agent, a model or a folder, templates for restarts and switches, and syncing
libraries between Macs other than through a file.
