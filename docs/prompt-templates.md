# Prompt templates

A prompt template is a prompt with fields to fill in — `Review {{url}}` — ready to start a session
from. Templates are managed in **File ▸ Manage Prompt Templates…**, and picked at the top of the New
Session sheet, or straight from **File ▸ New Session from** (⇧⌘N opens the first one).

## Syntax

| Written | Means |
|---|---|
| `{{url}}` | A required field named `url`. `{{ url }}` and `{{URL}}` are the same field. |
| `{{focus?}}` | An optional field. Marked optional once, a field is optional everywhere it appears. |
| `{{url\|/merge_requests\/(\d+)/}}` | Only part of the field's value — here `1315` out of `…/merge_requests/1315/diffs`. |
| `\{{` | Two literal braces: `\{{url}}` is the text `{{url}}`, not a field. |

A name starts with a letter and holds letters, digits, `-` and `_`, 40 characters at most. Anything
else between double braces — `{{payload.url}}`, `{{ items[0] }}`, `{{#each}}` — stays text: prompts
are full of code that uses the same braces. The editor underlines those so they are not mistaken for
fields.

The same field used twice is asked for once. A template has at most 20 fields, and its text at most
16 KB, the most either agent accepts.

### Keeping part of a value

`{{url|/pattern/}}` does not add a field: it uses the value of `url`, and keeps what a regular
expression finds in it — the first match, or its first group `( )` when the pattern has one. The
pattern runs from `|/` to the next `/` that is not escaped, so a slash inside it is written `\/`.
The syntax is ICU's, the one of `NSRegularExpression`.

A group lets the pattern say *where* the part is without keeping what surrounds it:
`{{url|/(?:merge_requests|pull)\/(\d+)/}}` gives the number of a GitLab merge request or a GitHub
pull request, whatever follows it in the URL — where `{{url|/\d+$/}}` would give the `42` of a
`#note_42` at its end.

A value the pattern finds nothing in adds nothing: the New Session sheet says so under the field,
and the preview shows `‹Url: no match›`, but the session can still be created. A pattern that is
not a regular expression keeps the template from being saved.

In the template editor, the **Try it** column on the right has a value to try per field: the
patterns applied to that field are listed under it with what they keep of the value typed there,
and where they are used. The same values make the preview below them.

The optional **session name** uses the same fields (`Review {{url}}`) and names the session until
you type a name of your own.

## What the agent receives

The prompt is rendered once, then sent exactly as the sheet previews it:

- A value is inserted as typed and never read again: a value holding `{{x}}` stays that text.
- Nothing is quoted. The prompt is handed to the agent as a single argument, with no shell in
  between, so `$`, quotes, backticks and a leading `--` arrive untouched.
- Line breaks become `\n`. Control characters other than tab and newline — an escape sequence pasted
  from a coloured terminal — are removed from template prompts and refused in a free prompt. A NUL
  character is refused everywhere: it would cut the prompt short.
- A one-line field is kept on one line, without its surrounding spaces; a multiline field only
  loses what trails it. An optional field left empty adds nothing.

The session keeps that rendered text, with the template's name and revision. Editing or deleting
the template later changes neither the session nor what **Restart** sends.

## Storage

Templates are kept in `~/Library/Application Support/com.hadrienl.VibeManager/templates.json`, beside
the sessions, with a `templates.backup.json` of the previous version. That file's shape is internal
and may change; use export and import to move templates between Macs.

## Export and import format

**Export…** writes a UTF-8 JSON file. **Import…** — or dropping a file on the window — reads one and
shows, before changing anything, which templates are new, identical (skipped) or changed. A changed
template is kept beside the existing one unless you choose **Replace**; a replaced template takes a
new revision, and sessions keep theirs.

```json
{
  "format": "vibe-manager.prompt-templates",
  "version": 1,
  "exportedAt": "2026-09-24T10:00:00.000Z",
  "templates": [
    {
      "id": "6F1C2A4E-7D35-4B8A-9E61-2C0D5B7A1E01",
      "name": "Review",
      "sessionName": "Review {{url|/(?:merge_requests|pull)\\/(\\d+)/}}",
      "body": "Review the merge request at {{url}}. Report correctness issues first.\n\n{{focus?}}",
      "fields": [
        { "name": "url", "label": "Merge request URL" },
        { "name": "focus", "label": "What to look at", "help": "Optional", "multiline": true }
      ]
    }
  ]
}
```

| Key | Type | |
|---|---|---|
| `format` | string, required | Always `vibe-manager.prompt-templates`. |
| `version` | integer, required | `1`. A file of a higher version is refused whole. |
| `exportedAt` | ISO 8601 date | Informative. |
| `templates[].id` | UUID, required | Identifies a template across libraries: importing the same `id` again is recognised. |
| `templates[].name` | string, required | Not empty. Suffixed ` 2`, ` 3`… on import when the name is taken. |
| `templates[].sessionName` | string | The session name pattern; empty or absent for none. |
| `templates[].body` | string, required | The prompt, not empty, at most 16 KB. |
| `templates[].fields[]` | array | Settings of the fields in the text; the fields themselves come from the text. |
| `fields[].name` | string, required | The field's name, as in `{{name}}`. |
| `fields[].label` | string | Shown next to the control; derived from the name when absent. |
| `fields[].help` | string | Shown in the empty control. |
| `fields[].multiline` | boolean | A text area rather than a single line. |

Whether a field is required is not a key: it is the `?` in the text. Revisions and dates are not
exported — a file has no history to impose on the library it lands in.

A file larger than 1 MB, of another `format`, or of a higher `version` is refused whole. A template
that is invalid on its own — no name, an empty or too long body, more than 20 fields — is listed as
skipped with its reason, and the others are imported.

JSON Schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["format", "version", "templates"],
  "properties": {
    "format": { "const": "vibe-manager.prompt-templates" },
    "version": { "type": "integer", "minimum": 1 },
    "exportedAt": { "type": "string", "format": "date-time" },
    "templates": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "name", "body"],
        "properties": {
          "id": { "type": "string", "format": "uuid" },
          "name": { "type": "string", "minLength": 1 },
          "sessionName": { "type": "string" },
          "body": { "type": "string", "minLength": 1 },
          "fields": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["name"],
              "properties": {
                "name": { "type": "string", "pattern": "^[A-Za-z][A-Za-z0-9_-]{0,39}$" },
                "label": { "type": "string" },
                "help": { "type": "string" },
                "multiline": { "type": "boolean" }
              }
            }
          }
        }
      }
    }
  }
}
```
