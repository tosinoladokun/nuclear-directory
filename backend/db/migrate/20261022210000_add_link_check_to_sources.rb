# The nightly link check (#510): when a cited source was last asked for,
# what it answered, and how many nights in a row it failed. Separate from
# the crawl's own columns, which describe the stored copy.
class AddLinkCheckToSources < ActiveRecord::Migration[8.1]
  STATUSES = %w[ok dead failing error blocked disallowed].freeze

  def change
    add_column :sources, :link_checked_at, :datetime
    add_column :sources, :link_status, :string
    add_column :sources, :link_http_status, :integer
    add_column :sources, :link_failures, :integer, default: 0, null: false
    add_check_constraint :sources, "link_status IS NULL OR link_status IN (#{STATUSES.map { |s| "'#{s}'" }.join(', ')})",
      name: "sources_link_status_check"
    add_index :sources, :link_checked_at
  end
end
