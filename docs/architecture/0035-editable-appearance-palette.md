# 0035 — Editable symbols and colours

- Status: accepted
- Date: 2026-09-30
- Issue: [#199](https://github.com/hadrienl/vibe-manager/issues/199)

## Context

The symbols and colours a session may wear were a closed catalogue, `SessionAppearanceCatalog`:
eight SF Symbols and eight colours, each checked for contrast in a test. They feed the New Session
picker, the prompt templates' picker, Change Icon… (#183, ADR 0034) and the identity a name is given
when the user picks nothing. #199 lets the user change both lists in the Settings.

## Decision

### The lists are an offer, never a rule of validity

`SessionAppearancePalette` (domain) holds the two lists: 1 to 48 each, no duplicate, colours as
`#RRGGBB`. It says what a picker offers and what a name is given. It never decides whether something
is valid:

- A session keeps the appearance it was stored with. Nothing is rewritten when a list changes.
- A picker shows the list, then the symbol or colour the session or template has when the list no
  longer offers it, dashed and said as "Not in the list of the Settings", so that it can be kept.
- `PromptTemplate.validate` only checks the appearance's shape (`appearanceMalformed`), never
  whether the lists offer it.

### The identity of a name follows the lists

`derived(forName:)` keeps its FNV-1a hash, applied to the current lists. With the shipped lists a
name looks exactly as before (a test pins a few names). Changed lists change what sessions created
afterwards are given, and what Revert to Default Icon gives: `EditSessionIdentity.defaultAppearance`
takes the palette, and `defaultAppearance(forName:projectIcon:)` is now the palette's.

### Contrast is checked when a colour is added

The badge is a white symbol on the colour, the same in light and dark, so one measure is enough: the
WCAG ratio of white on the colour must reach 3:1 (non-text contrast). A colour under it is refused,
and the same hue darkened just enough — channels scaled by one factor, found by halves, rounded down
— is offered instead. The shipped colours stay under test.

### Each list is stored on its own

`sessions.appearancePalette.v1` in the user defaults, as JSON. A list left as shipped is not
written: it follows the application when a later version ships another, and changing the colours
does not freeze the symbols. Each list is read on its own; one that cannot be read is the shipped
one and costs the other nothing.

### What this Mac cannot draw is hidden, not removed

A symbol added on a later macOS may not exist on an earlier one. `NSImage(systemSymbolName:)`
decides, once per name; a symbol it does not know is left out of the pickers and the Settings, and
stays in the preference.

### Names

The shipped colours have localized names (Indigo, Blue, Teal…), kept out of the stored lists so they
follow the application's language. A colour added may be given a name (40 characters at most); one
without is said by its hex. The shipped symbols have names since #183; one added is said by its SF
name, read as words.

## Consequences

- The Settings gain a Badges tab. Every change is kept at once, like the other tabs.
- The symbol search is a list of about 230 names with English keywords, filtered by what this Mac
  draws; any other SF Symbol can be typed by its exact name. macOS offers no public list of symbols,
  and the SF Symbols app's metadata is not ours to ship.
- Two copies of the application share the preference through the user defaults, as they share the
  other interface preferences.
