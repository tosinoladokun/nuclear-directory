# Data migrations

One-off data fixes, run once by the deploy's data step (`bin/deploy-data`,
#301) after the seed: a file per fix, `<14-digit timestamp>_<name>.rb`,
defining one `DeployData::Migration` subclass. The rules and an example are
in `backend/lib/deploy_data/migration.rb`. In short: `BY` names the human who
approved it, it's idempotent, it pins what the decision rests on, and it's
rehearsed with `bin/deploy-data --dry-run` on a restored backup before merge.
