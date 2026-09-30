#!/bin/zsh

# Every address the application hands to macOS goes through `LinkRouting` and `ExternalOpening`,
# which let out a page (in the default browser) or a mail address and nothing that would run
# (#245). This refuses any other way out that does not say why it is safe.
#
# It is a heuristic on the text, not a proof: it catches what is written plainly — an `open(` in a
# file that uses `NSWorkspace`, `openApplication`, `openURL(`, `LSOpen…`, `/usr/bin/open` — and
# wants, on the line or on the comment lines just above it, `// Opens outside: <reason>`. An open
# that is not safe yet is written `// Unsafe open, to fix in #<issue>: <why>`; those are listed on
# every run. Given files, checks them; otherwise the application's and the package's sources. Run
# by `Scripts/ci.sh`.

set -euo pipefail
setopt extended_glob

readonly repository_root="${0:A:h:h}"

if (( $# > 0 )); then
  sources=("$@")
else
  cd "$repository_root"
  sources=(App/**/*.swift(N) Packages/*/Sources/**/*.swift(N))
fi

# The part of `line` that is code: what precedes its first `//` outside a string literal.
code_of() {
  local line="$1" code="" quotes=0 i char
  for (( i = 1; i <= ${#line}; i++ )); do
    char="${line[i]}"
    if [[ "$char" == '"' ]]; then
      (( quotes += 1 ))
    elif [[ "$char" == / && "${line[i+1]:-}" == / ]] && (( quotes % 2 == 0 )); then
      break
    fi
    code+="$char"
  done
  print -r -- "$code"
}

# Whether `comment` gives a reason: `// Opens outside: <text>` or
# `// Unsafe open, to fix in #<n>: <text>`, with some text after the colon.
gives_reason() {
  [[ "$1" =~ '^//[[:space:]]*Opens outside:[[:space:]]*[^[:space:]]' ]] \
    || [[ "$1" =~ '^//[[:space:]]*Unsafe open, to fix in #[0-9]+:[[:space:]]*[^[:space:]]' ]]
}

readonly workspace_open='(^|[^[:alnum:]_])open[[:space:]]*(\(|;|$)|\.open([^[:alnum:]_]|$)'
readonly other_open='openApplication|(^|[^[:alnum:]_.])openURL[[:space:]]*\(|LSOpen|/usr/bin/open'

failures=0
unsafe=()
for file in $sources; do
  lines=("${(@f)$(<"$file")}")
  uses_workspace=0
  [[ "${(F)lines}" == *NSWorkspace* ]] && uses_workspace=1
  for (( n = 1; n <= ${#lines}; n++ )); do
    line="${lines[n]}"
    # Most lines say nothing of opening: only those are read closely, which is slow.
    [[ "$line" == *[oO]pen* || "$line" == *LSOpen* ]] || continue
    [[ "$line" =~ '^[[:space:]]*(//|\*)' ]] && continue
    code="$(code_of "$line")"
    # The way out every address is meant to take.
    code="${code//ExternalOpening.open/}"
    [[ "$code" =~ 'func[[:space:]]+(open|openURL)[[:space:]]*[(<]' ]] && continue
    opens=0
    (( uses_workspace )) && [[ "$code" =~ "$workspace_open" ]] && opens=1
    [[ "$code" =~ "$other_open" ]] && opens=1
    (( opens )) || continue

    reason=""
    comment="${line[${#code}+1,-1]}"
    comment="${comment##[[:space:]]#}"
    if [[ -n "$comment" ]] && gives_reason "$comment"; then
      reason="$comment"
    else
      # The comment lines right above, up to the first line that is not a comment.
      for (( above = n - 1; above >= 1; above-- )); do
        trimmed="${lines[above]##[[:space:]]#}"
        [[ "$trimmed" == //* ]] || break
        if gives_reason "$trimmed"; then
          reason="$trimmed"
          break
        fi
      done
    fi

    if [[ -z "$reason" ]]; then
      echo "$file:$n: opens outside the application without « // Opens outside: <reason> »" >&2
      (( failures += 1 ))
    elif [[ "$reason" == *"Unsafe open"* ]]; then
      unsafe+=("$file:$n: $reason")
    fi
  done
done

for entry in $unsafe; do
  echo "unsafe, tracked: $entry"
done

if (( failures > 0 )); then
  echo "Route the address through ExternalOpening, or say why it is safe to open." >&2
  exit 1
fi
