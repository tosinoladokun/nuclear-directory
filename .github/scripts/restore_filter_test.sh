#!/usr/bin/env bash
# Tests for backup/strip_attver.pl (#968): a backup restores into
# any Postgres 16, whichever pg_dump made it. Run by CI (blueprint job).
set -euo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s:\n--- expected\n%s\n--- got\n%s\n' "$1" "$3" "$2"; fail=1; fi; }
strip() { perl backup/strip_attver.pl 2>/dev/null; }

check "drops a statement whose only option is pg_attver" \
  "$(printf 'CREATE TABLE public.t (id bigint);\nALTER TABLE ONLY public.t ALTER COLUMN id SET (pg_attver=205353458720);\n' | strip)" \
  "CREATE TABLE public.t (id bigint);"

check "keeps the other options of a column" \
  "$(printf 'ALTER TABLE ONLY public.t ALTER COLUMN id SET (n_distinct=-1, pg_attver=7);\n' | strip)" \
  "ALTER TABLE ONLY public.t ALTER COLUMN id SET (n_distinct=-1);"

check "handles a quoted column name and ALTER TABLE without ONLY" \
  "$(printf 'ALTER TABLE public."Odd Name" ALTER COLUMN "my col" SET (pg_attver=1);\nSELECT 1;\n' | strip)" \
  "SELECT 1;"

check "leaves a column option stock Postgres knows alone" \
  "$(printf 'ALTER TABLE ONLY public.t ALTER COLUMN id SET (n_distinct=-1);\n' | strip)" \
  "ALTER TABLE ONLY public.t ALTER COLUMN id SET (n_distinct=-1);"

# A text column whose row is exactly the statement the filter removes: only the
# COPY guard keeps it (Copilot, #969), so dropping the guard fails this check.
copy=$'COPY public.notes (body) FROM stdin;\nALTER TABLE ONLY public.t ALTER COLUMN id SET (pg_attver=3);\n\\.\nALTER TABLE ONLY public.t ALTER COLUMN id SET (pg_attver=3);'
check "never touches COPY data, even a row that is exactly the option's statement" \
  "$(printf '%s\n' "$copy" | strip)" \
  $'COPY public.notes (body) FROM stdin;\nALTER TABLE ONLY public.t ALTER COLUMN id SET (pg_attver=3);\n\\.'

check "says how many options it removed" \
  "$(printf 'ALTER TABLE ONLY public.t ALTER COLUMN a SET (pg_attver=1);\nALTER TABLE ONLY public.t ALTER COLUMN b SET (pg_attver=2);\n' | perl backup/strip_attver.pl 2>&1 >/dev/null)" \
  "Removed 2 pg_attver column options."

exit "$fail"
