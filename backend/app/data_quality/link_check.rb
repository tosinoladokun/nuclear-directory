# The nightly link check (#510): asks for each source a published fact
# cites, oldest check first, and records what it answered on the source.
# It never unpublishes, edits or removes anything; Data Quality reads the
# dead and failing ones (Metabase, sources.link_status) and a person decides.
#
#   DataQuality::LinkCheck.new.run # => { "checked" => 120, "dead" => [ids], … }
#
# - ok: it answered (a 304 too).
# - dead: 404 or 410.
# - error: anything else failed (5xx, timeout); failing after FAILING_AFTER
#   nights in a row.
# - blocked: 401/403 or a bot wall. Never dead, never worked around.
# - disallowed: robots.txt says no.
class DataQuality::LinkCheck
  PER_NIGHT = 150
  FAILING_AFTER = 3
  # Enough to know it answered; the page itself isn't kept.
  MAX_BYTES = 64.kilobytes
  DEAD = [ 404, 410 ].freeze

  def initialize(fetcher: DataQuality::Fetcher.new, limit: PER_NIGHT, clock: -> { Time.current })
    @fetcher = fetcher
    @limit = limit
    @clock = clock
  end

  def run
    stats = { "checked" => 0 }
    due.each do |source|
      status = check(source)
      stats["checked"] += 1
      (stats[status] ||= []) << source.id unless status == "ok"
    end
    stats
  end

  # Sources cited by a published fact, never checked first, then the longest unchecked.
  def due
    Source.where(id: cited_ids).order(Arel.sql("link_checked_at ASC NULLS FIRST"), :id).limit(@limit)
  end

  private
    def cited_ids
      SourceCatalog::LIVE_TYPES.map do |type|
        Evidence.where(subject_type: type, subject_id: type.constantize.published.select(:id)).select(:source_id)
      end.reduce { |all, ids| all.or(ids) }
    end

    def check(source)
      response = @fetcher.get(source.url, max_bytes: MAX_BYTES)
      failures = source.link_failures
      status =
        case response.kind
        when :ok, :not_modified then "ok"
        when :blocked then "blocked"
        when :disallowed then "disallowed"
        else
          failures += 1
          if DEAD.include?(response.status) then "dead"
          elsif failures >= FAILING_AFTER then "failing"
          else "error"
          end
        end
      failures = 0 if %w[ok blocked disallowed].include?(status)
      source.update_columns(link_checked_at: @clock.call, link_status: status, link_http_status: response.status, link_failures: failures)
      status
    end
end
