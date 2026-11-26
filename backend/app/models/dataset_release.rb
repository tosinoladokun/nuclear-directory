# One version of the open dataset (#950): the draft built from production on
# the 1st, which Data Quality checks, and what publishing it to the data repo
# did. The files are in DatasetReleaseFile, so a list of releases never loads
# them.
class DatasetRelease < ApplicationRecord
  STATUSES = %w[draft published failed].freeze

  has_many :files, -> { order(:path) }, class_name: "DatasetReleaseFile", inverse_of: :release, dependent: :delete_all

  validates :version, presence: true, uniqueness: true, format: { with: /\A\d{4}\.\d{2}\z/ }
  validates :status, inclusion: { in: STATUSES }

  scope :newest_first, -> { order(version: :desc) }

  def draft? = status == "draft"
  def published? = status == "published"
  def failed? = status == "failed"
  def tag = "v#{version}"

  # The counts in the tables' own order (jsonb keeps its own key order).
  def ordered_counts = Dataset::Export::TABLES.keys.filter_map { |table| [ table, counts[table] ] if counts.key?(table) }.to_h

  # Publishing started once a commit exists: from then on the files are what
  # was committed, so a rebuild would publish something else under that tag.
  def rebuildable? = !published? && commit_sha.blank?
  def publishable? = !published? && built_at.present?

  # The tables the next release includes: the five core tables, as in
  # v2026.11, plus deal_terms or licensing_stages only when DATASET_TABLES
  # names them on purpose (Data Quality, #951; it decides at each sign-off).
  def self.tables_setting
    listed = ENV["DATASET_TABLES"].to_s.split(/[\s,]+/)
    Dataset::Export::TABLES.keys & (listed | Dataset::Export::CORE_TABLES)
  end

  # Publishing needs the data repo token (Tosin adds it on Render). Never
  # shown or logged; only whether it's there.
  def self.publishing_set_up? = ENV["DATASET_GITHUB_TOKEN"].present?
end
