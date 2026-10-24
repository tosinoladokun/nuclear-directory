# A lead (#484): a name that isn't a fact yet, from wherever it came up.
# sources: [{ "key", "label", "url", "times", "first", "last" }], one per
# place it came from (a search, a news claim…), so syncing again only
# updates that entry. seen_count, first_seen_on and last_seen_on sum them up.
class Lead < ApplicationRecord
  KINDS = %w[company plant other].freeze
  STATUSES = %w[new researching added ignored].freeze
  RECORD_TYPES = %w[Organization Facility].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true, prefix: :status
  validates :name, :normalized_name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :reason, presence: true, if: :status_ignored?
  validates :record_type, inclusion: { in: RECORD_TYPES }, allow_nil: true

  def self.normalize(name) = name.to_s.downcase.gsub(/[^\p{Alnum}]+/, " ").squish

  # Notes one sighting from a source (by its key), adding the lead if new.
  # A sighting seen before only updates its own entry. Returns the lead.
  def self.sighted!(name:, kind:, key:, label:, url: nil, times: 1, first: Date.current, last: first)
    name = name.to_s.squish.first(200)
    normalized = normalize(name)
    return if normalized.length < 2

    transaction(requires_new: true) do
      lead = lock.find_or_initialize_by(kind:, normalized_name: normalized)
      lead.name = name if lead.new_record?
      seen = lead.sources.find { |source| source["key"] == key }
      # A source seen before keeps its earliest first and latest last date.
      first = [ first, (Date.parse(seen["first"]) if seen) ].compact.min
      last = [ last, (Date.parse(seen["last"]) if seen) ].compact.max
      entry = { "key" => key, "label" => label, "url" => url, "times" => [ times.to_i, 1 ].max, "first" => first.to_s, "last" => last.to_s }.compact
      lead.sources = lead.sources.reject { |source| source["key"] == key } + [ entry ]
      lead.seen_count = lead.sources.sum { |source| source["times"].to_i }
      lead.first_seen_on = lead.sources.map { |source| Date.parse(source["first"]) }.min
      lead.last_seen_on = lead.sources.map { |source| Date.parse(source["last"]) }.max
      lead.save!
      lead
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def record = (record_type.constantize.find_by(id: record_id) if record_type && RECORD_TYPES.include?(record_type))

  def decide!(status, by:, reason: nil, record: nil)
    update!(status:, reason: (reason if status == "ignored"), record_type: record&.class&.name || (record_type if status == "researching"),
      record_id: record&.id || (record_id if status == "researching"), decided_by: by, decided_at: Time.current)
  end
end
