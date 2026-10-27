# A lead (#484): a name that isn't a fact yet, from wherever it came up.
# sources: [{ "key", "label", "url", "times", "first", "last" }], one per
# place it came from (a search, a news claim…), so syncing again only
# updates that entry. seen_count, first_seen_on and last_seen_on sum them up.
class Lead < ApplicationRecord
  KINDS = %w[company plant other].freeze
  # triage (Tosin, 27 Oct): what visitors searched, kept out of To do until
  # a source also names it or it's been searched SEARCHES_TO_PROMOTE times.
  STATUSES = %w[triage new researching added ignored].freeze
  SEARCHES_TO_PROMOTE = 3
  PROFANITY = %w[fuck shit cunt bitch dick porn sex asshole].freeze
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
      # A lead first seen in a search waits in triage.
      lead.status = "triage" if lead.new_record? && key.start_with?("search:")
      lead.sources = lead.sources.reject { |source| source["key"] == key } + [ entry ]
      lead.seen_count = lead.sources.sum { |source| source["times"].to_i }
      lead.first_seen_on = lead.sources.map { |source| Date.parse(source["first"]) }.min
      lead.last_seen_on = lead.sources.map { |source| Date.parse(source["last"]) }.max
      lead.status = "new" if lead.status_triage? && promotable?(lead)
      lead.save!
      lead
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # Out of triage: another source names it too, or it's been searched often enough.
  def self.promotable?(lead)
    lead.sources.any? { |source| !source["key"].to_s.start_with?("search:") } ||
      lead.sources.sum { |source| source["key"].to_s.start_with?("search:") ? source["times"].to_i : 0 } >= SEARCHES_TO_PROMOTE
  end

  # A search not worth keeping as a lead (Tosin, 27 Oct): fewer than three
  # letters, an address or email, gibberish, profanity, or a name we have.
  def self.junk?(query)
    text = query.to_s.squish
    letters = text.scan(/\p{L}/).size
    return true if letters < 3 || text.match?(%r{https?://|www\.|\.(com|org|net|gov|io)\b|@}i)
    words = text.downcase.scan(/\p{L}+/)
    return true if words.any? { |word| PROFANITY.include?(word) }
    # Gibberish: a long word with no vowel, or one letter over and over.
    return true if words.any? { |word| (word.length >= 5 && !word.match?(/[aeiouy]/)) || word.match?(/(.)\1{3,}/) }

    false
  end

  def record = (record_type.constantize.find_by(id: record_id) if record_type && RECORD_TYPES.include?(record_type))

  def decide!(status, by:, reason: nil, record: nil)
    update!(status:, reason: (reason if status == "ignored"), record_type: record&.class&.name || (record_type if status == "researching"),
      record_id: record&.id || (record_id if status == "researching"), decided_by: by, decided_at: Time.current)
  end
end
