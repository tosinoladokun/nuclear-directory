#!/usr/bin/env bash
# Decrypts a backup and restores it into an EMPTY database, then prints row
# counts to compare with the ones in the backup job's log.
#
#   restore <file.dump.age> <age key file> <target database url>
#
# Refuses a target that already has tables, so it can't overwrite live data.
set -euo pipefail

file="${1:?backup file}" key="${2:?age key file}" target="${3:?target database url}"

tables="$(psql "$target" --no-psqlrc --tuples-only --no-align \
  --command "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
if [[ "$tables" != "0" ]]; then
  echo "Target database already has ${tables} tables; restore only into an empty database." >&2
  exit 1
fi

age --decrypt --identity "$key" "$file" | pg_restore --no-owner --no-acl --exit-on-error --dbname "$target"

echo "Restored. Row counts:"
psql "$target" --no-psqlrc --quiet --tuples-only --no-align --field-separator=' ' --command "
  SELECT table_name,
         (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', table_name), false, true, '')))[1]::text
  FROM information_schema.tables
  WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    AND table_name <> 'solid_cache_entries'
  ORDER BY table_name"
