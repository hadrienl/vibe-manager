#!/bin/zsh

# The mobile companion's CloudKit schema (#396, ADR 0041), kept in Configuration/CloudKit/
# companion.ckdb and applied to the real container's Development environment with cktool:
#
#   Scripts/companion-schema.sh validate   # the file against Development, without changing it
#   Scripts/companion-schema.sh import     # the file into Development
#   Scripts/companion-schema.sh export     # Development's schema, printed
#   Scripts/companion-schema.sh reset      # Development back to Production, its data deleted
#   Scripts/companion-schema.sh production # Production's schema, printed
#
# cktool reaches Development alone: Production is deployed from the CloudKit console, « Deploy
# Schema Changes », and that is final — a Production schema only grows. Deploy what Development
# holds once it matches this file exactly: export, compare, then deploy.
#
# cktool needs a management token, made in the CloudKit console (Settings, Tokens & Keys) and saved
# once with `xcrun cktool save-token --type management`.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly schema="$repository_root/Configuration/CloudKit/companion.ckdb"
readonly team="QMJKZ67Z3H"
readonly container="iCloud.eu.hadrien.VibeManager"

cktool() {
  xcrun cktool "$@" --team-id "$team" --container-id "$container"
}

case "${1:-}" in
  validate) cktool validate-schema --environment development --file "$schema" ;;
  import) cktool import-schema --environment development --file "$schema" ;;
  export) cktool export-schema --environment development ;;
  reset) cktool reset-schema ;;
  production) cktool export-schema --environment production ;;
  *)
    print -u2 "usage: ${0:t} validate | import | export | reset | production"
    exit 2
    ;;
esac
