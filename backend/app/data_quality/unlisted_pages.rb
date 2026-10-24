# For plug-ins that read one page per record from an index (#386, #387,
# #388), the way NrcDecommissioning handles its site pages: when a complete
# index read no longer links a page, the page's undecided claims wait in
# review and each published fact it supported gets one review item; when the
# index links it again, its withdrawn claims go back where match left them.
# Nothing is unpublished; a person decides.
#
# A plug-in includes it and calls:
#   withdraw_unlisted(listed_urls, run, reason) # after a complete index read
#   restore_listed(page, reason)                # for each page still linked
#   flag_published(page, run, reason)           # e.g. a page that stopped stating its fact
module DataQuality::UnlistedPages
  WITHDRAWN = "withdrawn"
  KEEP_OR_UNPUBLISH = "Approve to keep it as it is; if it's no longer true, unpublish it on its page."
  OPEN = %w[new matched needs_review].freeze

  # Pages of this plug-in's kind the index no longer links (only ones not
  # held for this already). Returns how many claims were withdrawn or flagged.
  def withdraw_unlisted(listed_urls, run, reason)
    Source.where(source_kind:).where.not(url: listed_urls).where("status_reason IS DISTINCT FROM ?", reason).order(:id).sum do |page|
      Candidate.transaction do
        page.lock!
        waiting = page.candidates.where(status: OPEN).where("review_origin IS DISTINCT FROM 'dropped'").order(:id).lock.to_a
        withdrawn = waiting.count do |claim|
          next false if claim.review_origin == WITHDRAWN

          claim.update!(status: "needs_review", review_origin: WITHDRAWN, notes: joined_note(claim.notes, reason))
        end
        # Held, so extract doesn't read its stored copy (even one never read
        # before) while it's unlisted; a clean read when it's linked again
        # lifts it, and restore_listed asks for a fresh read then.
        page.update!(crawl_status: "needs_human", status_reason: reason) unless page.crawl_needs_human? && page.status_reason == reason
        withdrawn + flag_published(page, run, reason)
      end
    end
  end

  # A page the index links again (or readable again): its withdrawn claims a
  # person hasn't decided return, and if it was missing since its last
  # support, its stored read is cleared so extract and match record fresh
  # support. A later disappearance is then flagged again, even when the
  # earlier warning was decided.
  def restore_listed(page, reason)
    # Only after a clean read: a failed or partial return leaves them waiting.
    return 0 unless page.crawl_ok? && page.status_reason.blank?

    Candidate.transaction do
      page.lock!
      restored = page.candidates.status_needs_review.where(review_origin: WITHDRAWN).order(:id).lock.to_a.count do |claim|
        claim.update!(status: claim.subject_id ? "matched" : "new", review_origin: nil, notes: joined_note(claim.notes, reason))
      end
      page.update!(extracted_sha256: nil, extracted_rows_sha256: nil) if missing_since_support?(page)
      restored
    end
  end

  # One review item per published fact the page supported, once per absence:
  # not again while one is open or after a person decided one, until the page
  # states it again.
  def flag_published(page, run, reason)
    directory = DataQuality::DirectoryClient.new
    supported = page.candidates.where(status: %w[merged confirmed]).where.not(subject_id: nil)
      .where("review_origin IS DISTINCT FROM 'dropped'").order(:id).to_a
    supported.group_by { |claim| [ claim.subject_type, claim.subject_id ] }.count do |(type, id), claims|
      last = claims.last
      next false unless directory.published?(type:, id:)
      next false if page.candidates.where(subject_type: type, subject_id: id, review_origin: "dropped").where("id > ?", last.id).exists?

      page.candidates.create!(kind: last.kind, payload: last.payload, quote: last.quote, status: "needs_review",
        review_origin: "dropped", subject_type: type, subject_id: id, crawl_run: run,
        notes: "#{reason} (read on #{Date.current}). #{KEEP_OR_UNPUBLISH}")
    end
  end

  # Whether the page was withdrawn or flagged as missing after the last claim that supported it.
  def missing_since_support?(page)
    last_support = page.candidates.where(status: %w[merged confirmed]).where("review_origin IS DISTINCT FROM 'dropped'").maximum(:id).to_i
    page.candidates.where(review_origin: [ WITHDRAWN, "dropped" ]).where("id > ?", last_support).exists?
  end

  # Takes over a page someone cited by hand: its stored copy is the whole
  # page, so it's cleared and fetched afresh, then converted.
  def take_over(source)
    return unless source.source_kind == "web_page"

    source.update!(source_kind:, fetched_at: nil, etag: nil, last_modified: nil, content_text: nil, content_sha256: nil,
      extracted_sha256: nil, extracted_rows_sha256: nil)
  end

  # A page blocked on an earlier fetch (today's rerun gets skipped_recent): the stop holds.
  def still_blocked?(page) = page.blocked_streak.positive?

  private
    def joined_note(notes, reason) = [ notes.presence, reason ].compact.join(". ")
end
