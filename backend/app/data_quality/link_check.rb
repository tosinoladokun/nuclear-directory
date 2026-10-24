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

  def initialize(fetcher: DataQuality::Fetcher.new, limit: PER_NIGHT, clock: -> { Time.current }, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @directory = directory
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

  # Sources cited by any published fact (every fact type, roles and deal
  # terms too), never checked first, then the longest unchecked; not one
  # checked today, so a rerun can't count one day's outage as several
  # nights. Only the columns the check reads: a stored page can be megabytes.
  def due
    today = @clock.call.in_time_zone.beginning_of_day
    Source.where(id: @directory.published_source_ids).where("link_checked_at IS NULL OR link_checked_at < ?", today)
      .select(:id, :url, :link_failures)
      .order(Arel.sql("link_checked_at ASC NULLS FIRST"), :id).limit(@limit)
  end

  private

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
