# A search on the site that found nothing (#483): the normalised query (lower
# case, single spaces), when it was first and last searched and how often.
# Nothing about who searched. The admin marks each one Research (a lead to
# find and add), Covered (a spelling of something listed, #431) or Ignore.
# A gap closes on its own once the same search finds something.
#
#   SearchGap.record("Ocean Atomics", results: 0)   # opened, or counted again
#   SearchGap.record("ocean atomics", results: 1)   # closed: it finds a record now
class SearchGap < ApplicationRecord
  STATUSES = %w[open research covered ignored closed].freeze
  DECISIONS = { "research" => "Research", "covered" => "Covered", "ignored" => "Ignore" }.freeze
  # What isn't kept: an email address, or a phone number someone typed (a run
  # of digits, spaces, brackets, dots, plus signs and dashes, Unicode dashes
  # too, with seven digits or more).
  PHONE_RUN = /[\d\s().+\-\u2010-\u2015\u2212]+/
  def self.personal?(query) = query.include?("@") || query.scan(PHONE_RUN).any? { |run| run.count("0-9") >= 7 }

  enum :status, STATUSES.index_by(&:itself), validate: true, prefix: :status

  validates :query, presence: true, uniqueness: true, length: { in: 3..100 }

  scope :waiting, -> { where(status: %w[open research]) }

  def self.normalize(query) = query.to_s.downcase.squish.first(100)

  # Records one search: a miss is counted (a gap closed earlier opens again);
  # a hit closes the gap it was. Returns nothing.
  # The query as typed, screened whole before it's shortened.
  def self.record(query, results:, today: Date.current)
    return if personal?(query.to_s)

    query = normalize(query)
    return if query.length < 3

    if results.to_i.zero?
      now = Time.current
      upsert({ query:, searches_count: 1, first_searched_on: today, last_searched_on: today, status: "open", created_at: now, updated_at: now },
        unique_by: :query, record_timestamps: false,
        on_duplicate: Arel.sql("searches_count = search_gaps.searches_count + 1, last_searched_on = EXCLUDED.last_searched_on, " \
          "status = CASE WHEN search_gaps.status = 'closed' THEN 'open' ELSE search_gaps.status END, " \
          "closed_at = CASE WHEN search_gaps.status = 'closed' THEN NULL ELSE search_gaps.closed_at END, updated_at = EXCLUDED.updated_at"))
    else
      waiting.where(query:).update_all(status: "closed", closed_at: Time.current, updated_at: Time.current)
    end
    nil
  end

  # The admin's decision on it (Research, Covered or Ignore), as `by`.
  def decide!(status, by:)
    raise ArgumentError, "not a decision: #{status.inspect}" unless DECISIONS.key?(status.to_s)

    update!(status:, decided_by: by, decided_at: Time.current)
  end
end
