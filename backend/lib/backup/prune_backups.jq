# Published backups to delete, oldest first (so a failure partway through never
# leaves an older backup behind a deleted newer one), keeping the newest $keep
# of each kind: daily (backup-YYYY-MM-DDTHHMMZ) and pre-deploy
# (backup-YYYY-MM-DDTHHMMZ-predeploy, #301), so deploys never push out the
# dailies. From the REST API's release list; prints "<id> <tag>" per line.
# Sorted by tag name: created_at is the tagged commit's date, the same for
# every backup.
[.[] | select((.draft | not) and (.tag_name | startswith("backup-")))]
| group_by(.tag_name | endswith("-predeploy"))
| map(sort_by(.tag_name) | reverse | .[$keep:])
| add // []
| sort_by(.tag_name) | .[] | "\(.id) \(.tag_name)"
