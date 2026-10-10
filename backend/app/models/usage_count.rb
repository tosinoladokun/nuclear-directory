# Anonymous daily usage counters (#45). Each row is "this many page views of
# this path" or "this many searches for this query" on one day. Nothing about
# who: no cookies, IP addresses or user agents are stored, and no third-party
# trackers are used.
#
#   UsageCount.track_page_view("/companies/terrapower")
#   UsageCount.track_search(params[:q], results: results.size)
#
# Report: bin/rails "usage:report[30]"
class UsageCount < ApplicationRecord
  EVENTS = %w[page_view search search_no_results].freeze
  MAX_KEY_LENGTH = 200

  enum :event, EVENTS.index_by(&:itself), validate: true

  validates :day, :key, presence: true

  scope :since, ->(day) { where(day: day..) }

  # The query as it's counted: lowercase, single spaces, at most 200 characters,
  # so "TerraPower " and "terrapower" are one search.
  def self.normalize_query(query)
    query.to_s.unicode_normalize(:nfkc).downcase.squish.first(MAX_KEY_LENGTH).presence
  end

  def self.track_page_view(path, day: Date.current)
    increment(:page_view, path.to_s.first(MAX_KEY_LENGTH), day)
  end

  # Counts a search, and separately whether it found nothing, so the report
  # can list what people look for and don't find.
  def self.track_search(query, results:, day: Date.current)
    key = normalize_query(query) or return

    increment(:search, key, day)
    increment(:search_no_results, key, day) if results.to_i.zero?
  end

  # Most counted keys for one event since a day, as [[key, count], ...].
  def self.top(event, since:, limit: 20)
    public_send(event).since(since).group(:key).order(Arel.sql("SUM(count) DESC"), :key).limit(limit).sum(:count).to_a
  end

  # One statement, so concurrent requests can't lose a count.
  def self.increment(event, key, day)
    return if key.blank?

    now = Time.current
    upsert({ day: day, event: event.to_s, key: key, count: 1, created_at: now, updated_at: now },
      unique_by: %i[day event key],
      on_duplicate: Arel.sql("count = usage_counts.count + 1, updated_at = EXCLUDED.updated_at"))
  end
  private_class_method :increment
end
