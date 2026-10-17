# Draft backups abandoned by earlier runs whose upload failed (never
# restorable), to delete: drafts whose tag's time is over 2 hours before
# $now (epoch seconds). A newer draft may be another run's upload in
# progress (the daily cron job and a deploy's pre-deploy backup can overlap,
# #301), so it's left alone. A tag whose time can't be read is kept. Prints
# release ids.
.[]
| select(.draft and (.tag_name | startswith("backup-")))
| select((try (.tag_name[7:23] | strptime("%Y-%m-%dT%H%MZ") | mktime) catch $now) < $now - 7200)
| .id
