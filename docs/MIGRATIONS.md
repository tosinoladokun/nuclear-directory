# Migration checklist

**Who reviews what (22 Oct 2026).** The author reviews a purely additive migration against this checklist, ticks it in the PR body, and Database skims it in one line. Additive means only a new table, column, index, check or extension: no data changed, no grants, nothing dropped or renamed. Everything else gets a full review from Database before READY, including data changes, backfills, grants or revokes, deletes, drops, renames, type changes and anything touching backups or `metabase_ro`.

## Author's checklist (paste into the PR body)

- [ ] **Additive only:** no `UPDATE`/`DELETE`, no `drop`/`rename`/`change_column`, no `GRANT`/`REVOKE`.
- [ ] **Reversible:** `change` reverses on its own, or `down` is written. Ran `db:migrate`, `db:rollback`, `db:migrate` locally.
- [ ] **Safe defaults:** a new `null: false` column on an existing table has a default. Checks on an existing table pass for every row already there (or add them `validate: false`).
- [ ] **No lock-heavy steps on big tables** (`candidates`, `evidence`, `sources`, `verification_events`): no column rewrite, no default that rewrites the table. Add indexes on those tables with `algorithm: :concurrently` and `disable_ddl_transaction!`.
- [ ] **Metabase:** a new table is private by default. Add it to `PRIVATE_TABLES` in `lib/metabase/readonly_role.rb` if it records people (who clicked, emails, IPs). Reading it in Metabase needs a grant, which is a full review.
- [ ] **schema.rb:** only your table, column or check, plus the version bump to your migration's timestamp. Your timestamp is newer than main's. Undo unrelated lines Rails rewrites (`::text[]` check forms).
- [ ] **Extensions:** only ones Render Postgres supports (`pg_trgm`, `unaccent`, `citext` and the like). A dump restores them.
- [ ] **Backup and restore unaffected:** no new role, schema or tablespace, and nothing outside `public`.
