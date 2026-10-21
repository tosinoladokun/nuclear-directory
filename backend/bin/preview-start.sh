#!/usr/bin/env bash
# Start command for the free UI preview service (render.yaml,
# nuclear-directory-preview). Never used by the live site.
#
# Every start replaces the preview database's contents (its own, owned by
# preview_app; never production) with a fresh schema and seed, so nothing from
# an earlier preview, including tables from another PR's migrations, survives.
set -euo pipefail

case "${DATABASE_URL:-}" in
  */nuclear_directory_preview|*/nuclear_directory_preview\?*) ;;
  *) echo "preview-start: DATABASE_URL must point at nuclear_directory_preview; refusing to reset it." >&2; exit 1 ;;
esac

# preview_app's 5-second statement_timeout protects the shared database from
# the running preview; the setup below can take longer on the free instance,
# so these commands (only) get 2 minutes. The server started at the end
# doesn't inherit it.
timeouts="-c statement_timeout=120s -c lock_timeout=20s"

# Render can run several starts at once (a newer label push, a retry after a
# failed start), and each takes minutes before the server opens its port.
# So every start builds in its own schema and tags its sessions, and none of
# them touches another's work in progress (16 Oct: one start's reset wiped
# another's half-built schema, "unknown role" and lock timeouts).
# The time, then random digits: containers often share small PIDs, so the
# PID alone couldn't tell two starts in the same second apart.
build="$(date -u +%s)$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
schema="preview_next_${build}"
export PGAPPNAME="preview-build-${build}"
psql_setup() { PGOPTIONS="$timeouts" psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

# Sessions to end: the old instance's (they hold locks on public and it
# reconnects), and a build's only when it has sat idle for over a minute,
# in a transaction or not (its container was killed mid-build; even without
# locks it uses up one of preview_app's few connections). An active build is
# left alone. preview_app may end its own sessions.
end_others="SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
  WHERE datname = current_database() AND pid <> pg_backend_pid() AND usename = current_user
    AND (application_name NOT LIKE 'preview-build-%'
         OR (state LIKE 'idle%' AND state_change < now() - interval '60 seconds'));"
with_retries() {
  local what=$1 sql=$2 attempt
  for attempt in 1 2 3 4 5; do
    psql_setup -c "$end_others" -c "$sql" > /dev/null && return 0
    [[ $attempt == 5 ]] && { echo "preview-start: couldn't ${what} after 5 tries." >&2; return 1; }
    echo "preview-start: ${what} failed (attempt ${attempt}); retrying in $((attempt * 3))s." >&2
    sleep $((attempt * 3))
  done
}

# This start's schema, plus a sweep of other builds' schemas over 30 minutes
# old (their starts died; the number in the name is when they began) and the
# fixed-name ones the earlier version of this script used.
with_retries "prepare ${schema}" "
  CREATE SCHEMA ${schema};
  DO \$\$ DECLARE s text; BEGIN
    FOR s IN SELECT nspname FROM pg_namespace
             WHERE (nspname ~ '^preview_next_[0-9]+$'
                    AND left(substring(nspname from 14), 10)::bigint < extract(epoch from now())::bigint - 1800)
                OR nspname IN ('preview_next', 'preview_old') LOOP
      EXECUTE format('DROP SCHEMA %I CASCADE', s);
    END LOOP;
  END \$\$;"
# The build. Seeding takes plant-name advisory locks, which cover the whole
# database, not one schema, so a write on the old preview (still serving, for
# example an admin action during QA) can hold one past lock_timeout (17 Oct,
# #320). On a failure: end the old instance's sessions, start the schema
# afresh and try again. After 3 tries this start fails and the old preview
# keeps serving.
built=""
for attempt in 1 2 3; do
  if PGOPTIONS="$timeouts -c search_path=${schema}" bin/rails db:schema:load db:seed; then
    built=1
    break
  fi
  [[ $attempt == 3 ]] && break
  echo "preview-start: building the preview data failed (attempt ${attempt}); retrying in $((attempt * 5))s." >&2
  sleep $((attempt * 5))
  with_retries "reset ${schema}" "DROP SCHEMA IF EXISTS ${schema} CASCADE; CREATE SCHEMA ${schema};" || exit 1
done
if [[ -z "$built" ]]; then
  echo "preview-start: couldn't build the preview data after 3 tries; the old preview keeps serving." >&2
  exit 1
fi

# The preview's admin login, from PREVIEW_ADMIN_PASSWORD. A problem here (unset
# or rejected password) is logged and never stops the preview.
if ! PGOPTIONS="$timeouts -c search_path=${schema}" bin/rails preview:admin; then
  echo "preview-start: no admin login on this preview (see the line above); starting without it." >&2
fi

# The swap, in one transaction and one at a time (an advisory lock), after
# ending the old instance's sessions. The last start to finish is the one
# that serves. A failure here leaves the old data in place.
with_retries "swap in the new preview data (the old data is still in place)" "
  SELECT pg_advisory_xact_lock(hashtext('preview-swap'));
  DO \$\$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'public') THEN
      EXECUTE 'ALTER SCHEMA public RENAME TO preview_old_${build}';
    END IF;
  END \$\$;
  ALTER SCHEMA ${schema} RENAME TO public;
  DROP SCHEMA IF EXISTS preview_old_${build} CASCADE;" || exit 1

unset PGAPPNAME
exec ./bin/rails server
