# Fetches one Source and records the result on it: a new snapshot
# (content, hash, ETag, and the page's title when it has one) on success,
# or crawl_status blocked / needs_human with the reason. Shared by all
# plug-ins.
#
#   DataQuality::Snapshot.take(source, fetcher: fetcher)
#   # => :changed, :unchanged, :skipped_recent, :blocked, :disallowed or :error
class DataQuality::Snapshot
  # Blocked this many fetches in a row: stop treating it as temporary.
  BLOCKED_STREAK_LIMIT = 3

  # binary: fetch raw bytes. With a block, the block turns the fetched body
  # into the text that's stored (e.g. the rows of a spreadsheet that matter),
  # and the hash is of that text, so unrelated changes to the file don't
  # count as changes. max_bytes: a larger limit than the Fetcher's for a
  # source known to be bigger (EIA's yearly zip, about 24 MB).
  def self.take(source, fetcher:, binary: false, max_bytes: DataQuality::Fetcher::MAX_BYTES, &to_text)
    claim(source) { take_claimed(source, fetcher:, binary:, max_bytes:, &to_text) }
  end

  # Runs the block with the source's row locked and re-read, so the
  # once-a-day check, the fetch and recording it can't interleave with
  # another fetch of the same source (a pipeline run, the title backfill).
  # An error is raised after the lock is released, so what the block
  # recorded (e.g. a failed conversion as today's fetch) is kept.
  def self.claim(source)
    error = nil
    result = source.with_lock do
      yield
    rescue StandardError => e
      error = e
      nil
    end
    raise error if error

    result
  end

  def self.take_claimed(source, fetcher:, binary:, max_bytes:, &to_text)
    # At most one fetch per source per calendar day (in the app's time zone).
    return :skipped_recent if source.fetched_at&.to_date == Date.current

    response = fetcher.get(source.url, etag: source.etag, last_modified: source.last_modified, binary:, max_bytes:)
    attempt = { fetched_at: Time.current, http_status: response.status }

    case response.kind
    when :ok
      if response.truncated
        # Half a page would look like a changed page; keep the last good snapshot.
        source.update!(attempt.merge(status_reason: "Larger than #{max_bytes / 1.megabyte} MB; not stored"))
        return :error
      end

      text = convert(response.body, source, attempt, &to_text)
      sha = Digest::SHA256.hexdigest(text)
      changed = sha != source.content_sha256
      title = DataQuality::PageTitle.from(response.body, content_type: response.content_type) unless binary
      source.update!(attempt.merge(fresh(source, response))
        .merge(content_text: text, content_sha256: sha, title: title || source.title))
      changed ? :changed : :unchanged
    when :not_modified
      source.update!(attempt.merge(fresh(source, response)))
      :unchanged
    when :blocked
      streak = source.blocked_streak + 1
      reason = response.reason
      reason = "Blocked #{streak} fetches in a row; last: #{reason}" if streak >= BLOCKED_STREAK_LIMIT
      source.update!(attempt.merge(blocked_streak: streak, status_reason: reason,
        crawl_status: streak >= BLOCKED_STREAK_LIMIT ? "needs_human" : "blocked"))
      :blocked
    when :disallowed
      source.update!(attempt.merge(crawl_status: "needs_human", status_reason: response.reason))
      :disallowed
    else
      # Temporary (server error, timeout): keep the last good snapshot and try tomorrow.
      source.update!(attempt.merge(status_reason: response.reason))
      :error
    end
  end

  # The body as the text to store. A conversion that fails still counts as
  # today's fetch, so a rerun the same day doesn't download the file again.
  def self.convert(body, source, attempt)
    block_given? ? yield(body) : body
  rescue StandardError
    source.update!(attempt)
    raise
  end
  private_class_method :convert, :take_claimed

  # A successful fetch clears any block. Validators are only replaced when
  # the server sends new ones (a 304 may omit them). final_url: where the
  # page ended after redirects (#525), nil when it didn't redirect.
  def self.fresh(source, response)
    { crawl_status: "ok", status_reason: nil, blocked_streak: 0, final_url: (response.url if response.url.present? && response.url != source.url),
      etag: response.etag || source.etag, last_modified: response.last_modified || source.last_modified }
  end
  private_class_method :fresh
end
