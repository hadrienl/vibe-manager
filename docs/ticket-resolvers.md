# Ticket resolvers

When a new session names a ticket's address — in its Ticket field, its name, or its prompt,
including a template's values — Vibe Manager opens the ticket's page in the session's web view and
puts its title at the top of the session's notes:

```
[acme/app#42] Permettre l'export CSV — https://github.com/acme/app/issues/42
```

The page is read where you are signed in: if the site asks you to sign in, the notes say so, with
**Show Tab**. Sign in there, and the line is added once the ticket's page is back. Nothing is read
again when the session is restarted or restored.

A **resolver** says which addresses are tickets. An address no enabled resolver recognises is never
loaded. GitHub, GitLab, GitLab merge requests, Jira Cloud and Linear are shipped; you can change,
switch off, duplicate or delete them, and add your own in **Settings › Tickets**.

## A resolver

| Field | What it is |
|---|---|
| Name | Shown in the settings. |
| Address pattern | A regular expression (ICU syntax, as `NSRegularExpression` reads it) matched from the start of the address. It must end where the address ends, or before `/`, `?` or `#`: `…/issues/42` recognises `…/issues/42/files`, not `…/issues/420`. The scheme and the host are compared in lower case. It must have at least one **named capture**, `(?<number>[0-9]+)`. |
| Identifier | Shown before the title: the captures written in braces, and `{host}`. Two addresses with the same identifier are the same ticket. |
| Title cleanup | Regular expressions whose matches are removed from the page's title, in order. The title read is `og:title`, else `twitter:title`, else the page's `<title>`. |

### Example: a Redmine

| Field | Value |
|---|---|
| Name | `Redmine Acme` |
| Address pattern | `https://redmine\.acme\.fr/issues/(?<number>[0-9]+)` |
| Identifier | `#{number}` |
| Title cleanup | `^[^#]*#[0-9]+: ` then ` - Redmine$` |

« Anomalie #77: Le rapport plante - Redmine » becomes `[#77] Le rapport plante — https://…`.

### A self-hosted GitLab or Jira

Duplicate the GitLab (or Jira Cloud) resolver and change the host in its pattern: for example
`https://git\.acme\.fr/(?<project>…` in place of `https://gitlab\.com/(?<project>…`.

## The line

**Settings › Tickets › Line format**, `[{id}] {title} — {url}` by default. `{title}` is required;
`{id}` and `{url}` are optional. The line is added as an edit of the notes: ⌘Z takes it back.

## Export and import format

**Export…** writes a UTF-8 JSON file; **Import…** reads one. A resolver whose `id` is already in the
list replaces it; a name already taken is suffixed ` 2`, ` 3`…; an invalid resolver is left out and
counted, and the others are imported.

```json
{
  "exportedAt" : "2026-09-27T10:00:00.000Z",
  "format" : "vibe-manager.ticket-resolvers",
  "resolvers" : [
    {
      "id" : "0F3B8D6E-2C47-4F6A-9E2B-6A1D5C7E8F90",
      "isEnabled" : true,
      "name" : "Redmine Acme",
      "pattern" : "https://redmine\\.acme\\.fr/issues/(?<number>[0-9]+)",
      "shortID" : "#{number}",
      "titleCleanup" : ["^[^#]*#[0-9]+: ", " - Redmine$"]
    }
  ],
  "version" : 1
}
```

| Key | Type | Meaning |
|---|---|---|
| `format` | string, required | `vibe-manager.ticket-resolvers`. |
| `version` | integer, required | `1`. A later version is refused whole. |
| `exportedAt` | ISO 8601 date | Informative. |
| `resolvers[].id` | UUID, required | Identifies a resolver across lists. |
| `resolvers[].name` | string, required | Not empty. |
| `resolvers[].pattern` | string, required | A regular expression with at least one named capture. |
| `resolvers[].shortID` | string, required | Captures and `{host}` in braces. |
| `resolvers[].titleCleanup` | array of strings | Regular expressions. Absent: none. |
| `resolvers[].isEnabled` | boolean | Absent: `true`. |

A resolver holds no command and no secret: importing a file loads nothing by itself.

## Storage

Resolvers are kept in `~/Library/Application Support/com.hadrienl.VibeManager/ticket-resolvers.json`;
the switch and the line format in the application's preferences. No token is stored: the pages are
read with the web view's own sign-in.
