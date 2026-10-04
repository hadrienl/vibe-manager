#!/bin/zsh

# Every string of every catalog translated into every language of the application
# (docs/localization.md): each plural variant of the language included, none left stale by the
# compiler or marked for review. The languages are the project's `knownRegions`, English and Base
# aside. Run by `Scripts/ci.sh`; given catalogs as arguments, it checks those instead of the
# repository's, and `--languages fr,de` checks those languages instead of the project's.

set -euo pipefail

readonly repository_root="${0:A:h:h}"

languages=()
if [[ "${1:-}" == --languages ]]; then
  languages=(${(s:,:)2})
  shift 2
fi
if (( ${#languages} == 0 )); then
  # The block `knownRegions = ( en, Base, fr, "zh-Hans", … );` of the project, one region a line.
  languages=(${(f)"$(/usr/bin/sed -n '/knownRegions = (/,/);/p' \
    "$repository_root/VibeManager.xcodeproj/project.pbxproj" \
    | /usr/bin/sed -e '1d' -e '$d' -e 's/[[:space:]",]//g' | /usr/bin/grep -vx -e en -e Base)"})
fi
if (( ${#languages} == 0 )); then
  echo "No language to check." >&2
  exit 1
fi

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

# The plural categories each language needs (Unicode CLDR, as Xcode offers them).
readonly plural_categories='{
  "ar": ["zero", "one", "two", "few", "many", "other"],
  "de": ["one", "other"], "es": ["one", "many", "other"], "fr": ["one", "many", "other"],
  "hi": ["one", "other"], "it": ["one", "many", "other"], "ja": ["other"], "ko": ["other"],
  "nl": ["one", "other"], "pl": ["one", "few", "many", "other"],
  "pt-BR": ["one", "many", "other"], "ru": ["one", "few", "many", "other"],
  "tr": ["one", "other"], "uk": ["one", "few", "many", "other"], "zh-Hans": ["other"],
  "zh-Hant": ["other"]
}'

for language in $languages; do
  if ! /usr/bin/jq -e --arg language "$language" 'has($language)' <<< "$plural_categories" \
    > /dev/null; then
    echo "No plural categories known for \"$language\": add them to $0." >&2
    exit 1
  fi
done

# One line per string that is not ready, "<key>	<reason>". A string marked not to be translated is
# left alone. The units are read wherever they are: a plain string, plural variants, substitutions.
readonly problems='
  .strings | to_entries[] | select(.value.shouldTranslate != false)
  | .key as $key | .value as $string
  | ([$string.localizations // {} | .[] | .variations.plural? // empty] | length > 0) as $plural
  | if $string.extractionState == "stale" then "\($key)\tstale: no longer in the code"
    elif any($string.localizations // {} | .. | objects | select(has("stringUnit")) | .stringUnit;
      .state == "needs_review") then "\($key)\tneeds review"
    else
      $languages[] as $language
      | ($string.localizations[$language] // null) as $translation
      | ([$translation | .. | objects | select(has("stringUnit")) | .stringUnit]) as $units
      | ($categories[$language] - (($translation.variations.plural? // {}) | keys)) as $missing
      | if $translation == null or ($units | length) == 0 then "\($key)\tno \($language) translation"
        elif any($units[]; .state != "translated" or (.value // "") == "") then
          "\($key)\t\($language) translation not finished"
        elif $plural and ($missing | length) > 0 then
          "\($key)\t\($language) plural variants missing: \($missing | join(", "))"
        else empty end
    end
'

readonly languages_json="$(print -rl -- $languages | /usr/bin/jq -R . | /usr/bin/jq -sc .)"

failed=0
for catalog in $catalogs; do
  if ! report=$(/usr/bin/jq -r --argjson languages "$languages_json" \
    --argjson categories "$plural_categories" "$problems" "$catalog"); then
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
  echo "Some strings are not ready in every language (${(j:, :)languages})." >&2
  exit 1
fi
echo "Every string is translated into ${#languages} language(s), in ${#catalogs} catalog(s)."
