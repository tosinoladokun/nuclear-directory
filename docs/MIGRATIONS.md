# Migration checklist

**Who reviews what (22 Oct 2026).** The author reviews a purely additive migration against this checklist, ticks it in the PR body, and Database skims it in one line. Additive means only a new table, column, index, check or extension: no data changed, no grants, nothing dropped or renamed. Everything else gets a full review from Database before READY, including data changes, backfills, grants or revokes, deletes, drops, renames, type changes and anything touching backups or `metabase_ro`.

## Author's checklist (paste into the PR body)

- [ ] **Additive only:** no `UPDATE`/`DELETE`, no `drop`/`rename`/`change_column`, no `GRANT`/`REVOKE`.
- [ ] **Reversible:** `change` reverses on its own, or `down` is written. Ran `db:migrate`, `db:rollback`, `db:migrate` locally.
- [ ] **Safe defaults:** a new `null: false` column on an existing table has a default. A check on an existing table passes for every row already there. On a big table (below) it is added with `validate: false`, committed, and validated in a separate later migration: a plain `ADD CHECK` scans every row under an `ACCESS EXCLUSIVE` lock, and validating in the same transaction keeps that lock for the scan.
- [ ] **No lock-heavy steps on big tables** (`candidates`, `evidence`, `sources`, `verification_events`): no column rewrite, no default that rewrites the table. Add indexes on those tables with `algorithm: :concurrently` and `disable_ddl_transaction!`.
- [ ] **Metabase:** every new table is classified in `lib/metabase/readonly_role.rb`, or `test/lib/metabase/readonly_role_test.rb` fails CI. Put it in `PRIVATE_TABLES` (or a `PRIVATE_PREFIXES` entry) if it records people (who clicked, emails, IPs). A table that Metabase should read goes in `READABLE_TABLES` with its grants, which is a full review.
- [ ] **schema.rb:** only your table, column, index, check or `enable_extension` line, plus the version bump to your migration's timestamp. Your timestamp is newer than main's. Undo unrelated lines Rails rewrites (`::text[]` check forms).
- [ ] **Extensions:** only ones Render Postgres supports (`pg_trgm`, `unaccent`, `citext` and the like). A dump restores them.
- [ ] **Backup and restore unaffected:** no new role, schema or tablespace, and nothing outside `public`.
