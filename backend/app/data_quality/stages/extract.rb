# Turns each crawled source into candidate facts via the plug-in.
# A source whose content hasn't changed since its last extraction is
# skipped. A plug-in may send a candidate straight to review by returning
# status: "needs_review" and the reason in notes; it's marked
# review_origin: "extract".
#
# Re-extracting a changed source replaces what came from its old
# snapshot and wasn't acted on yet: candidates still new, and ones extract
# itself sent to review. Candidates that moved on (matched, merged,
# rejected, or sent to review by a later stage) are left alone.
class DataQuality::Stages::Extract < DataQuality::Stage
  private
    def perform(run)
      stats = { "sources" => 0, "candidates" => 0, "unchanged" => 0, "empty" => 0 }
      deferred = deferred_new_sources

      sources.crawl_ok.find_each do |source|
        # Over the plug-in's nightly cap of new sources (#513): read on a later night.
        if deferred.include?(source.id)
          stats["deferred"] = stats.fetch("deferred", 0) + 1
          next
        end

        # Nothing stored, nothing to extract (not the same as a page whose
        # layout changed, which the plug-in reports).
        if source.content_text.blank?
          stats["empty"] += 1
          next
        end

        if source.content_sha256.present? && source.content_sha256 == source.extracted_sha256
          stats["unchanged"] += 1
          reconfirm(source, source.extracted_rows_sha256 || remember_rows(source))
          next
        end

        # The page changed but its rows didn't (NRC's list carries a date
        # stamp, #240): nothing new to propose, so the plug-in, and any model
        # it calls, isn't run.
        snapshot = source.content_sha256
        rows = plugin.rows_sha256(source)
        if rows.present? && rows == source.extracted_rows_sha256
          same_rows = Candidate.transaction do
            source.lock!
            next false unless source.crawl_ok? && source.content_sha256 == snapshot

            source.update!(extracted_sha256: snapshot)
          end
          if same_rows
            stats["rows_unchanged"] = stats.fetch("rows_unchanged", 0) + 1
            reconfirm(source, rows)
            next
          end
        end

        # The plug-in may take minutes (model calls with retries), so it runs
        # before the transaction: no locks held meanwhile, and if it fails
        # the source's existing candidates are untouched.
        # One candidate per claim: a row that repeats one (a company named on
        # several rows) isn't proposed twice.
        extracted = plugin.extract(source, run).uniq { |attrs| [ attrs[:kind].to_s, attrs[:payload].to_h ] }.map do |attrs|
          attrs = attrs.slice(:kind, :payload, :quote, :status, :notes)
          attrs[:review_origin] = "extract" if attrs[:status].to_s == "needs_review"
          attrs.merge(crawl_run: run)
        end
        # Every news claim's headline and summary, from the source's own text.
        extracted = DataQuality::NewsDraft.new.apply(extracted, plugin:, source:, run:)

        # Results belong to the snapshot they were read from, from a source
        # that's still usable. If a crawl stored new content or flagged the
        # source (blocked, needs_human) meanwhile, or another run already
        # extracted this snapshot, they're discarded rather than written.
        written = Candidate.transaction do
          source.lock!
          next false unless source.crawl_ok?
          next false if source.content_sha256 != snapshot || source.extracted_sha256 == snapshot

          stale(source).delete_all
          extracted.each { |attrs| source.candidates.create!(attrs) }
          source.update!(extracted_sha256: snapshot, extracted_rows_sha256: rows)
          true
        end

        unless written
          stats["superseded"] = stats.fetch("superseded", 0) + 1
          next
        end
        stats["candidates"] += extracted.size
        stats["sources"] += 1
      end

      stats
    end

    # The source was read and still says what it said (#240): the facts its
    # last extracted rows support (approved or confirmed from them, with
    # their quotes) were checked when it was fetched. Not after a failed
    # fetch, which keeps the old content but still moves fetched_at.
    # Only facts whose quote the source still has: a read that found nothing
    # (a page that stopped naming its licensees) writes no candidates, so the
    # last read's are still the ones here, and their quotes may be gone.
    # Sources never read before beyond the plug-in's nightly cap, in its order
    # (e.g. largest awards first); nil cap, none.
    def deferred_new_sources
      limit = plugin.new_sources_per_run or return Set.new
      fresh = sources.crawl_ok.where(extracted_sha256: nil).where.not(content_text: [ nil, "" ]).to_a
      plugin.new_source_order(fresh).drop(limit).to_set(&:id)
    end

    def reconfirm(source, rows)
      return if rows.blank? || source.status_reason.present?

      from_rows = source.candidates.where(crawl_run_id: last_read(source), status: %w[merged confirmed]).where.not(subject_id: nil)
      still = from_rows.select(:kind, :subject_type, :subject_id, :quote, :payload).select { |row| plugin.quote_in_source?(source, row.quote) }
      # A news claim's subject is the company it's about; its evidence is on the news item it wrote (#535).
      facts = still.map { |row| (id = row.kind == "news_item" && row.payload["news_item_id"]) ? [ "NewsItem", id ] : [ row.subject_type, row.subject_id ] }
      directory.reconfirm_source(source_id: source.id, facts: facts.uniq,
        quotes: still.map(&:quote).uniq, rows_sha256: rows, at: source.fetched_at || Time.current)
    end

    # A source extracted before rows were hashed (#240) gets its hash from the
    # snapshot it was extracted from, while that's still the stored one.
    def remember_rows(source)
      rows = plugin.rows_sha256(source) or return
      Candidate.transaction do
        source.lock!
        next unless source.content_sha256 == source.extracted_sha256 && source.extracted_rows_sha256.nil?

        source.update!(extracted_rows_sha256: rows)
        rows
      end
    end

    # The extract run that wrote the source's current candidates.
    def last_read(source)
      source.candidates.where("review_origin IS DISTINCT FROM 'dropped'").maximum(:crawl_run_id)
    end

    # A candidate a person reopened (#228) is kept with its reopenings.
    # A claim Data Quality acted on keeps its audit (#548), even once undone:
    # it isn't deleted as stale.
    def stale(source)
      source.candidates.status_new.or(source.candidates.status_needs_review.where(review_origin: "extract"))
        .where("candidates.reopenings = '[]'::jsonb").where.not(id: DqAction.select(:candidate_id))
        # Nor a proposal made from a lead (#572): it isn't this extract's row.
        .where("candidates.notes IS NULL OR candidates.notes NOT LIKE 'Proposed from a lead%'")
    end
end
