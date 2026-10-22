# The language of archive rules

<!-- Written by `ArchiveRuleGrammar.document`; VIBE_WRITE_ARCHIVE_RULES_DOC=1 writes it again. -->

What an agent writes from a sentence of the user, and what the application reads to archive sessions on its own (#405, ADR 0043). The interface never shows it: the user reads what the application says of a rule, in their language. Only sessions in Done are archived, a session where something runs is skipped, and one the user took out of the archive is not sent back.

## Grammar

```ebnf
document   = { rule | protection } ;
rule       = "rule" string selection schedule { option } ;
selection  = "archive" "done" "sessions" [ "where" expr ] ;
protection = "protect" "where" expr ;
schedule   = "on" ( "daily" "at" time
                  | "weekdays" "at" time
                  | "weekly" weekday { "," weekday } "at" time
                  | "monthly" monthday { "," monthday } "at" time
                  | "every" duration [ "at" time ]
                  | "continuously" ) ;
monthday   = 1..31 | "last" "day" | ordinal weekday ;
ordinal    = "first" | "second" | "third" | "fourth" | "last" ;
weekday    = "monday" | "tuesday" | "wednesday" | "thursday" | "friday" | "saturday" | "sunday" ;
expr       = term { "or" term } ;
term       = factor { "and" factor } ;
factor     = "not" factor | "(" expr ")" | test ;
test       = field comparison value | "ticket" ( "present" | "absent" ) | "git.dirty" ;
comparison = "=" | "!=" | "in" | "contains" | "~" | ">=" | "<=" | "before" | "after" | "under" ;
value      = color | string | identifier | integer | duration | day | "[" value { "," value } "]" ;
option     = "limit" integer | "no" "catch-up" ;
color      = "#" 6 * hexdigit ;                   (* #B42318 *)
string     = '"' { character } '"' ;              (* \" and \\ inside *)
duration   = integer ( "m" | "h" | "d" | "w" ) ;  (* 30m 48h 3d 2w *)
day        = yyyy "-" mm "-" dd ;                 (* 2026-11-01 *)
time       = hh ":" mm ;                          (* 00:00 to 23:59 *)
```

Keywords are lower case. `//` starts a comment that runs to the end of the line. A rule's name is at most 60 characters, and two rules never share one. A text holds at most 20 rules and 20 protections.

## Fields

| Field | Comparisons | Values | Meaning | Example |
|---|---|---|---|---|
| `badge.color` | `=` `!=` `in` | `#RRGGBB` | The colour the session's badge shows, as `#RRGGBB`. A badge that shows the project's icon shows no colour and never matches. | `badge.color in [#B42318, #A65B00]` |
| `badge.symbol` | `=` `!=` `in` | a text in quotes | The SF Symbol the badge shows, by its name. Never matches a project icon. | `badge.symbol = "ladybug"` |
| `badge.kind` | `=` `!=` | `symbol`, `projectIcon` | `symbol`, or `projectIcon` when the badge shows the project's icon. | `badge.kind = projectIcon` |
| `name` | `=` `!=` `in` `contains` `~` | a text in quotes | The session's name. | `name contains "spike"` |
| `project` | `=` `!=` `in` `contains` `~` | a text in quotes | The name of the session's group (its folder's name, or the name given to it). | `project = "vibe-manager"` |
| `folder` | `under` | a text in quotes | The session's working folder, with `under` and a path (`~` is the home folder). | `folder under "~/Code/client"` |
| `agent` | `=` `!=` `in` | an identifier | The agent's identifier: one of the agents installed, or an endpoint's. | `agent = codex` |
| `model` | `=` `!=` `in` `contains` `~` | a text in quotes | The model's identifier; a session on the agent's default model has none. | `model contains "sonnet"` |
| `ticket` | `present` `absent` | — | `ticket present` when the session works on a ticket, `ticket absent` otherwise. | `ticket present` |
| `ticket.host` | `=` `!=` `in` `contains` `~` | a text in quotes | The host of the ticket's address, such as `github.com`. | `ticket.host = "github.com"` |
| `git.branch` | `=` `!=` `in` `contains` `~` | a text in quotes | The branch checked out in the session's folder. | `git.branch ~ "release/*"` |
| `git.dirty` | `present` | — | The session's folder has changes not committed. `not git.dirty` for a clean folder. | `not git.dirty` |
| `coordination` | `=` `!=` | `none`, `coordinator`, `child` | `none`, `coordinator`, or `child` (of a coordinator). | `coordination = child` |
| `created.since` | `>=` `<=` | a duration | Time since the session was created. | `created.since >= 30d` |
| `activity.since` | `>=` `<=` | a duration | Time since the session was last touched. | `activity.since >= 2w` |
| `closed.since` | `>=` `<=` | a duration | Time since its agent was last stopped. | `closed.since >= 12h` |
| `done.since` | `>=` `<=` | a duration | Time since the session last arrived in Done. | `done.since >= 48h` |
| `created` | `before` `after` | a day | The day the session was created. | `created before 2026-11-01` |
| `activity` | `before` `after` | a day | The day the session was last touched. | `activity after 2026-10-01` |
| `closed` | `before` `after` | a day | The day its agent was last stopped. | `closed before 2026-11-01` |
| `done` | `before` `after` | a day | The day the session last arrived in Done. | `done before 2026-11-01` |
| `done.first` | `before` `after` | a day | The day the session first arrived in Done. | `done.first before 2026-10-01` |
| `reopened` | `=` `!=` `>=` `<=` | a whole number | How many times the session left Done for another column. | `reopened = 0` |

- Texts are compared without regard to case or accents. `~` takes a pattern where `*` is any characters and `?` one character; it is not a regular expression.
- `in` takes a list in brackets: `badge.color in [#B42318, #A65B00]`.
- A duration counts time gone by: a day is 24 hours.
- A day is read in the Mac's time zone: `before 2026-11-01` is before that day starts, `after 2026-11-01` from the next day on.
- `done.since` counts from the **last** time the session arrived in Done: a session reopened and done again starts over.

## Schedules

| Form | Meaning |
|---|---|
| `daily at 18:00` | every day |
| `weekdays at 18:00` | Monday to Friday |
| `weekly friday at 18:00` | one or more days: `weekly monday, thursday at 09:00` |
| `monthly 15 at 18:00` | one or more days of the month: `monthly 1, 15 at 08:00` |
| `monthly last day at 23:00` | the last day of the month; also `first monday`, `last friday` |
| `every 3d at 08:00`, `every 6h` | an interval counted from when the rule is turned on, from 15m to 52w; with a time, in days or weeks |
| `continuously` | as soon as a session matches |

- Times are on the Mac's clock. A time the clocks skip is the first one that exists; a time they repeat runs once.
- A day of the month a month does not have (31 in April) is that month's last day.
- A time missed while the Mac is off or the application closed is caught up once, when it comes back. `no catch-up` waits for the next time instead.
- `limit N` archives at most N sessions a run, the longest done first.

## Protections

`protect where …` holds for every rule: a session a protection names is never archived. A “except …” or “never …” of a sentence becomes a protection when it is said of every rule, a `not` in the rule when it is said of one.

## Defaults

- No time said: **18:00**. “In the morning” 09:00, “at noon” 12:00, “in the evening” 18:00.
- “End of the week”: **friday**. “Start of the week”: monday.
- “End of the month”: `last day`. “Start of the month”: `1`.
- A colour: the colour of the palette with that name in the user's language. When several colours could be meant (“Red” and “Brick red”), ask.
- Anything else that is ambiguous is a question, never a guess.

## Examples

```
rule "Rouges, le 15"
  archive done sessions where badge.color = #B42318
  on monthly 15 at 18:00

rule "Vertes, en fin de semaine"
  archive done sessions where badge.color = #1E7F4D
  on weekly friday at 18:00

protect where project = "client-x" or badge.symbol = "pin.fill"

rule "Ménage du dernier vendredi"
  archive done sessions where done.since >= 3d and (agent = codex or git.branch ~ "spike/*") and not git.dirty and coordination != coordinator
  on monthly last friday at 17:30
  limit 30

rule "Enfants finis"
  archive done sessions where coordination = child and done.since >= 2h
  on continuously
```
