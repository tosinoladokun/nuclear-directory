#!/usr/bin/env bash
# Tests for backup/newest_backup.jq and backend/lib/backup/prune_backups.jq: the backups
# must be ordered by their tag's timestamp, never by GitHub's created_at (the
# tagged commit's date, the same for every backup). Run by CI (blueprint job).
set -euo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected [$3], got [$2]"; fail=1; fi; }

# All releases share one created date, as on GitHub; listed newest-first is
# not guaranteed, so they're shuffled here.
cli='[
  {"tagName":"backup-2026-10-11T1000Z","isDraft":false,"createdAt":"2026-10-10T16:24:59Z"},
  {"tagName":"backup-2026-10-13T0240Z","isDraft":false,"createdAt":"2026-10-10T16:24:59Z"},
  {"tagName":"backup-2026-10-20T1000Z","isDraft":true, "createdAt":"2026-10-10T16:24:59Z"},
  {"tagName":"v1","isDraft":false,"createdAt":"2027-01-01T00:00:00Z"},
  {"tagName":"backup-2026-10-10T1751Z","isDraft":false,"createdAt":"2026-10-10T16:24:59Z"}]'
check "newest published backup, ignoring drafts and other tags" \
  "$(jq -r -f backup/newest_backup.jq <<< "$cli")" "backup-2026-10-13T0240Z"
check "no backups gives nothing" "$(jq -r -f backup/newest_backup.jq <<< '[]')" ""

rest='[
  {"id":2,"tag_name":"backup-2026-10-11T1000Z","draft":false,"created_at":"2026-10-10T16:24:59Z"},
  {"id":4,"tag_name":"backup-2026-10-18T1000Z","draft":false,"created_at":"2026-10-10T16:24:59Z"},
  {"id":1,"tag_name":"backup-2026-10-10T1751Z","draft":false,"created_at":"2026-10-10T16:24:59Z"},
  {"id":9,"tag_name":"backup-2026-10-25T1000Z","draft":true, "created_at":"2026-10-10T16:24:59Z"},
  {"id":3,"tag_name":"backup-2026-10-13T0240Z","draft":false,"created_at":"2026-10-10T16:24:59Z"},
  {"id":7,"tag_name":"v1","draft":false,"created_at":"2026-10-10T16:24:59Z"}]'
check "keep 2: prune the two oldest backups only, oldest first" \
  "$(jq -r --argjson keep 2 -f backend/lib/backup/prune_backups.jq <<< "$rest" | tr '\n' ' ')" "1 backup-2026-10-10T1751Z 2 backup-2026-10-11T1000Z "
check "keep 12: prune nothing" "$(jq -r --argjson keep 12 -f backend/lib/backup/prune_backups.jq <<< "$rest")" ""

# Pre-deploy backups (#301) are kept apart, so a day of deploys never pushes
# out the daily backups.
mixed='[
  {"id":1,"tag_name":"backup-2026-10-10T0900Z","draft":false},
  {"id":2,"tag_name":"backup-2026-10-11T0900Z","draft":false},
  {"id":3,"tag_name":"backup-2026-10-11T1500Z-predeploy","draft":false},
  {"id":4,"tag_name":"backup-2026-10-11T1600Z-predeploy","draft":false},
  {"id":5,"tag_name":"backup-2026-10-11T1700Z-predeploy","draft":false},
  {"id":6,"tag_name":"backup-2026-10-12T0900Z","draft":false}]'
check "keep 2 of each kind: prune the oldest daily and the oldest pre-deploy, oldest first" \
  "$(jq -r --argjson keep 2 -f backend/lib/backup/prune_backups.jq <<< "$mixed" | tr '\n' ' ')" "1 backup-2026-10-10T0900Z 3 backup-2026-10-11T1500Z-predeploy "
check "a pre-deploy backup can be the newest to restore" \
  "$(jq -r -f backup/newest_backup.jq <<< '[{"tagName":"backup-2026-10-11T0900Z","isDraft":false},{"tagName":"backup-2026-10-11T1500Z-predeploy","isDraft":false}]')" "backup-2026-10-11T1500Z-predeploy"

# Only abandoned drafts are deleted: a recent one may be another run's
# upload in progress (the daily job and a pre-deploy backup can overlap).
now=$(jq -n '"2026-10-17T1200Z" | strptime("%Y-%m-%dT%H%MZ") | mktime')
drafts='[
  {"id":1,"tag_name":"backup-2026-10-17T0900Z","draft":true},
  {"id":2,"tag_name":"backup-2026-10-17T1130Z-predeploy","draft":true},
  {"id":3,"tag_name":"backup-2026-10-16T0900Z","draft":false},
  {"id":4,"tag_name":"backup-garbled","draft":true},
  {"id":5,"tag_name":"v1","draft":true}]'
check "delete only drafts over 2 hours old" \
  "$(jq -r --argjson now "$now" -f backend/lib/backup/abandoned_drafts.jq <<< "$drafts" | tr '\n' ' ')" "1 "

exit $fail
