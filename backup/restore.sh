#!/usr/bin/env bash
# Decrypts a backup and restores it into an EMPTY database, then prints row
# counts to compare with the ones in the backup job's log.
#
#   restore <file.dump.age> <age key file> <target database url>
#
# Refuses a target that already has tables, so it can't overwrite live data.
set -euo pipefail

file="${1:?backup file}" key="${2:?age key file}" target="${3:?target database url}"
# The file is decrypted twice (its versions, then the restore), so a key
# given on stdin ("-", as restore-latest does) is read once and kept in
# memory, never on disk.
if [[ "$key" == "-" ]]; then
  key_text="$(cat)"
fi
decrypt() {
  if [[ -n "${key_text:-}" ]]; then
    age --decrypt --identity <(printf '%s\n' "$key_text") "$file"
  else
    age --decrypt --identity "$key" "$file"
  fi
}

tables="$(psql "$target" --no-psqlrc --tuples-only --no-align \
  --command "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
if [[ "$tables" != "0" ]]; then
  echo "Target database already has ${tables} tables; restore only into an empty database." >&2
  exit 1
fi

# Which server and pg_dump made it: a dump from an older pg_dump than its
# server can carry options a restore target doesn't know (#968).
decrypt | pg_restore --list | grep -E '^;\s+Dumped (from|by)' || true

# The dump goes through SQL so column options the target may not know can be
# removed (strip-attver, #968: Postgres 16.16's pg_attver, which
# 16.16's own pg_dump leaves out and older servers refuse). One
# transaction: if anything fails, the target is left empty, ready to retry.
decrypt \
  | pg_restore --no-owner --no-acl --file=- \
  | strip-attver \
  | psql "$target" --no-psqlrc --quiet --single-transaction --set ON_ERROR_STOP=1 > /dev/null

echo "Restored. Row counts:"
psql "$target" --no-psqlrc --quiet --tuples-only --no-align --field-separator=' ' --command "
  SELECT table_name,
         (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', table_name), false, true, '')))[1]::text
  FROM information_schema.tables
  WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    AND table_name <> 'solid_cache_entries'
  ORDER BY table_name"
