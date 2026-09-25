#!/bin/zsh

# Every string of every catalog translated into French (docs/localization.md): each plural variant
# included, none left stale by the compiler or marked for review. Run by `Scripts/ci.sh`; given
# catalogs as arguments, it checks those instead of the repository's.

set -euo pipefail

readonly repository_root="${0:A:h:h}"

if (( $# > 0 )); then
  catalogs=("$@")
else
  cd "$repository_root"
  catalogs=(App/**/*.xcstrings(N) Packages/VibeManagerKit/Sources/**/*.xcstrings(N))
fi

if (( ${#catalogs} == 0 )); then
  echo "No string catalog found." >&2
  exit 1
fi

# One line per string that is not ready, "<key>	<reason>". A string marked not to be translated is
# left alone. The units are read wherever they are: a plain string, plural variants, substitutions.
readonly problems='
  .strings | to_entries[] | select(.value.shouldTranslate != false)
  | .key as $key | .value as $string
  | ($string.localizations.fr // null) as $french
  | ([$french | .. | objects | select(has("stringUnit")) | .stringUnit]) as $units
  | if $string.extractionState == "stale" then "\($key)\tstale: no longer in the code"
    elif any($string.localizations // {} | .. | objects | select(has("stringUnit")) | .stringUnit;
      .state == "needs_review") then "\($key)\tneeds review"
    elif $french == null or ($units | length) == 0 then "\($key)\tno French translation"
    elif any($units[]; .state != "translated" or (.value // "") == "") then
      "\($key)\tFrench translation not finished"
    elif ([$string.localizations[] | .variations.plural? // empty] | length) > 0
      and (($french.variations.plural // {}) | (has("one") and has("other")) | not) then
      "\($key)\tFrench plural variants missing"
    else empty end
'

failed=0
for catalog in $catalogs; do
  if ! report=$(/usr/bin/jq -r "$problems" "$catalog"); then
    echo "$catalog: not a readable string catalog" >&2
    failed=1
    continue
  fi
  if [[ -n "$report" ]]; then
    while IFS=$'\t' read -r key reason; do
      echo "$catalog: \"$key\": $reason" >&2
    done <<< "$report"
    failed=1
  fi
done

if (( failed )); then
  echo "Some strings are not ready in French." >&2
  exit 1
fi
echo "Every string is translated, in ${#catalogs} catalog(s)."
