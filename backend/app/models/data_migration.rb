# A one-off data fix from db/data/ that has run (#301): recorded in the same
# transaction as its changes, so it runs exactly once. See
# DeployData::Migration.
class DataMigration < ApplicationRecord
end
