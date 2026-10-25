import Foundation

/// The one definition of the language of archive rules in words: `docs/archive-rules.md` is this
/// text, and the agent is given it. A test keeps the file equal to it; `VIBE_WRITE_ARCHIVE_RULES_DOC=1`
/// writes the file again.
public enum ArchiveRuleGrammar {
  public static let grammar = """
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
    string     = '"' { character } '"' ;              (* \\" and \\\\ inside *)
    duration   = integer ( "m" | "h" | "d" | "w" ) ;  (* 30m 48h 3d 2w *)
    day        = yyyy "-" mm "-" dd ;                 (* 2026-11-01 *)
    time       = hh ":" mm ;                          (* 00:00 to 23:59 *)
    """

  /// The defaults the agent applies so that one sentence always gives the same rule.
  public static let defaults = """
    - No time said: **18:00**. “In the morning” 09:00, “at noon” 12:00, “in the evening” 18:00.
    - “End of the week”: **friday**. “Start of the week”: monday.
    - “End of the month”: `last day`. “Start of the month”: `1`.
    - A colour: the colour of the palette with that name in the user's language. When several \
    colours could be meant (“Red” and “Brick red”), ask.
    - Anything else that is ambiguous is a question, never a guess.
    """

  public static let examples = """
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
    """

  static func values(of field: ArchiveField) -> String {
    switch field.valueKind {
    case .color: "`#RRGGBB`"
    case .text: "a text in quotes"
    case .words(let words):
      words.isEmpty ? "an identifier" : words.map { "`\($0)`" }.joined(separator: ", ")
    case .integer: "a whole number"
    case .duration: "a duration"
    case .date: "a day"
    case .fact: "—"
    }
  }

  /// The fields, one line each: what the agent and the reference both list.
  public static var fields: String {
    var lines = [
      "| Field | Comparisons | Values | Meaning | Example |",
      "|---|---|---|---|---|",
    ]
    for field in ArchiveField.allCases {
      let comparisons = field.comparisons.map { "`\($0.rawValue)`" }.joined(separator: " ")
      lines.append(
        "| `\(field.keyword)` | \(comparisons) | \(values(of: field)) | \(field.summary) | "
          + "`\(field.example)` |")
    }
    return lines.joined(separator: "\n")
  }

  /// The language, as both the agent and a developer read it.
  public static var language: String {
    """
    ## Grammar

    ```ebnf
    \(grammar)
    ```

    Keywords are lower case. `//` starts a comment that runs to the end of the line. A rule's name \
    is at most \(ArchiveRuleParser.maximumNameLength) characters, and two rules never share one. A \
    text holds at most \(ArchiveRuleParser.maximumRules) rules and \
    \(ArchiveRuleParser.maximumProtections) protections.

    ## Fields

    \(fields)

    - Texts are compared without regard to case or accents. `~` takes a pattern where `*` is any \
    characters and `?` one character; it is not a regular expression.
    - `in` takes a list in brackets: `badge.color in [#B42318, #A65B00]`.
    - A duration counts time gone by: a day is 24 hours.
    - A day is read in the Mac's time zone: `before 2026-11-01` is before that day starts, \
    `after 2026-11-01` from the next day on.
    - `done.since` counts from the **last** time the session arrived in Done: a session reopened \
    and done again starts over.

    ## Schedules

    | Form | Meaning |
    |---|---|
    | `daily at 18:00` | every day |
    | `weekdays at 18:00` | Monday to Friday |
    | `weekly friday at 18:00` | one or more days: `weekly monday, thursday at 09:00` |
    | `monthly 15 at 18:00` | one or more days of the month: `monthly 1, 15 at 08:00` |
    | `monthly last day at 23:00` | the last day of the month; also `first monday`, `last friday` |
    | `every 3d at 08:00`, `every 6h` | an interval counted from when the rule is turned on, from \
    15m to 52w; with a time, in days or weeks |
    | `continuously` | as soon as a session matches |

    - Times are on the Mac's clock. A time the clocks skip is the first one that exists; a time \
    they repeat runs once.
    - A day of the month a month does not have (31 in April) is that month's last day.
    - A time missed while the Mac is off or the application closed is caught up once, when it \
    comes back. `no catch-up` waits for the next time instead.
    - `limit N` archives at most N sessions a run, the longest done first.

    ## Protections

    `protect where …` holds for every rule: a session a protection names is never archived. A \
    “except …” or “never …” of a sentence becomes a protection when it is said of every rule, a \
    `not` in the rule when it is said of one.

    ## Defaults

    \(defaults)

    ## Examples

    ```
    \(examples)
    ```
    """
  }

  /// `docs/archive-rules.md`.
  public static var document: String {
    """
    # The language of archive rules

    <!-- Written by `ArchiveRuleGrammar.document`; VIBE_WRITE_ARCHIVE_RULES_DOC=1 writes it again. -->

    What an agent writes from a sentence of the user, and what the application reads to archive \
    sessions on its own (#405, ADR 0043). The interface never shows it: the user reads what the \
    application says of a rule, in their language. Only sessions in Done are archived, a session \
    where something runs is skipped, and one the user took out of the archive is not sent back.

    \(language)

    """
  }
}
