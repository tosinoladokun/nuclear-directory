# Fuzzy name matching for search (#431): when an exact search finds nothing,
# DirectoryListing compares the query with names and aliases by trigram
# similarity ("brown ferry" finds Browns Ferry). pg_trgm is a trusted
# extension on Render's Postgres. The tables are small, so no trigram index yet.
class EnablePgTrgm < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
  end
end
