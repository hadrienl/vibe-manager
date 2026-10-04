#!/bin/zsh

# `Scripts/check-localizations.sh` against catalogs written for the occasion: it accepts a complete
# one, and refuses each way a string can be left unfinished, in one language or in several. Run by
# `Scripts/ci.sh`.

set -euo pipefail

readonly check="${0:A:h}/check-localizations.sh"
readonly fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT

# A catalog holding `strings`, a JSON object.
catalog() {
  local name="$1" strings="$2"
  print -r -- "{\"sourceLanguage\": \"en\", \"strings\": $strings, \"version\": \"1.0\"}" \
    > "$fixtures/$name.xcstrings"
  print -r -- "$fixtures/$name.xcstrings"
}

translated='{"stringUnit": {"state": "translated", "value": "Fermer"}}'
plural_fr='{"variations": {"plural": {
  "one": {"stringUnit": {"state": "translated", "value": "%lld fichier"}},
  "many": {"stringUnit": {"state": "translated", "value": "%lld fichiers"}},
  "other": {"stringUnit": {"state": "translated", "value": "%lld fichiers"}}}}}'
plural_en='{"variations": {"plural": {
  "one": {"stringUnit": {"state": "translated", "value": "%lld file"}},
  "other": {"stringUnit": {"state": "translated", "value": "%lld files"}}}}}'

# `expect <accepted|refused> <description> <catalog> [languages]`, French alone by default.
expect() {
  local outcome="$1" description="$2" file="$3" languages="${4:-fr}"
  if "$check" --languages "$languages" "$file" > /dev/null 2>&1; then
    [[ "$outcome" == accepted ]] || { echo "FAIL: $description was accepted" >&2; exit 1; }
  else
    [[ "$outcome" == refused ]] || { echo "FAIL: $description was refused" >&2; exit 1; }
  fi
  echo "ok: $description $outcome"
}

expect accepted "a complete catalog" "$(catalog complete "{
  \"Close\": {\"localizations\": {\"fr\": $translated}},
  \"%lld files\": {\"localizations\": {\"en\": $plural_en, \"fr\": $plural_fr}},
  \"Vibe Manager\": {\"shouldTranslate\": false}
}")"
expect refused "a string without French" "$(catalog missing '{"Close": {}}')"
expect refused "a French string left empty" "$(catalog empty '{
  "Close": {"localizations": {"fr": {"stringUnit": {"state": "translated", "value": ""}}}}
}')"
expect refused "a string no longer in the code" "$(catalog stale "{
  \"Close\": {\"extractionState\": \"stale\", \"localizations\": {\"fr\": $translated}}
}")"
expect refused "a string to review" "$(catalog review '{
  "Close": {"localizations": {"fr": {"stringUnit": {"state": "needs_review", "value": "Fermer"}}}}
}')"
expect refused "a plural translated as a single string" "$(catalog singular "{
  \"%lld files\": {\"localizations\": {\"en\": $plural_en, \"fr\": $translated}}
}")"
expect refused "a plural variant left untranslated" "$(catalog variant "{
  \"%lld files\": {\"localizations\": {\"en\": $plural_en, \"fr\": {\"variations\": {\"plural\": {
    \"one\": {\"stringUnit\": {\"state\": \"translated\", \"value\": \"%lld fichier\"}},
    \"other\": {\"stringUnit\": {\"state\": \"new\", \"value\": \"%lld files\"}}}}}}}
}")"

translated_de='{"stringUnit": {"state": "translated", "value": "Schließen"}}'
plural_ru='{"variations": {"plural": {
  "one": {"stringUnit": {"state": "translated", "value": "%lld файл"}},
  "few": {"stringUnit": {"state": "translated", "value": "%lld файла"}},
  "many": {"stringUnit": {"state": "translated", "value": "%lld файлов"}},
  "other": {"stringUnit": {"state": "translated", "value": "%lld файла"}}}}}'
plural_ru_short='{"variations": {"plural": {
  "one": {"stringUnit": {"state": "translated", "value": "%lld файл"}},
  "other": {"stringUnit": {"state": "translated", "value": "%lld файла"}}}}}'

expect accepted "a catalog complete in two languages" "$(catalog two "{
  \"Close\": {\"localizations\": {\"de\": $translated_de, \"fr\": $translated}}
}")" fr,de
expect refused "a string translated into French alone" "$(catalog french-only "{
  \"Close\": {\"localizations\": {\"fr\": $translated}}
}")" fr,de
expect accepted "a plural with every Russian variant" "$(catalog russian "{
  \"%lld files\": {\"localizations\": {\"en\": $plural_en, \"fr\": $plural_fr, \"ru\": $plural_ru}}
}")" fr,ru
expect refused "a Russian plural without few and many" "$(catalog russian-short "{
  \"%lld files\": {\"localizations\": {\"en\": $plural_en, \"fr\": $plural_fr, \"ru\": $plural_ru_short}}
}")" fr,ru
expect refused "a French plural without many" "$(catalog french-short "{
  \"%lld files\": {\"localizations\": {\"en\": $plural_en, \"fr\": {\"variations\": {\"plural\": {
    \"one\": {\"stringUnit\": {\"state\": \"translated\", \"value\": \"%lld fichier\"}},
    \"other\": {\"stringUnit\": {\"state\": \"translated\", \"value\": \"%lld fichiers\"}}}}}}}
}")"
expect refused "a language whose plural categories are unknown" "$(catalog unknown "{
  \"Close\": {\"localizations\": {\"fr\": $translated, \"xx\": $translated}}
}")" fr,xx
