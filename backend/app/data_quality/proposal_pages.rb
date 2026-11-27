# Data Quality's proposals (#934): a claim citing a page a person or Data
# Quality found by hand (a web_page source) can only be checked once the page
# is stored. Without it the verifier sends the claim to review ("The source
# has no stored content"), so even a blank fill Data Quality checked
# first-hand can't join Yes to all.
#
# After POST /api/dq/matching creates proposals, the pages their claims cite
# are fetched in a job (ProposalPagesJob), then match and verify run, so the
# verifier reads the page as stored:
# - A page with nothing stored is fetched.
# - A page whose stored text doesn't hold the new claim's quote is fetched
#   again: it may have changed since. If it did, earlier claims on it are
#   asked again on the next verify, as for any source whose content changes.
# - A page that blocks fetching, or robots.txt disallows, is recorded on the
#   source by Snapshot and stays unstored, so its claim goes to review as before.
# - A page is fetched at most once a day (Snapshot), and never one a person
#   has to look at (needs_human).
#
# Nothing else re-fetches a web_page source: once stored, a claim is checked
# against the page as it was then, like any snapshot.
module DataQuality::ProposalPages
  # The sources these claims cite that need fetching.
  def self.due(candidate_ids)
    plugin = DataQuality::Plugins::WebPage.new
    Candidate.where(id: candidate_ids).includes(:source).filter_map do |candidate|
      source = candidate.source
      next unless source.source_kind == "web_page" && !source.crawl_needs_human? && fetch_pending?(source, candidate)
      next if source.content_text.present? && plugin.quote_in_source?(source, candidate.quote)

      source.id
    end.uniq
  end

  # How long a new claim on a page waiting to be stored is left for its
  # job (ProposalPagesJob) before verify treats it as it did before #934.
  WAIT = 1.hour

  # True while a claim's page is being fetched for it: a web page not
  # fetched since the claim was made, for up to WAIT. Verify leaves such a
  # claim as it is, so a run already queued before the job doesn't send it
  # to review for a page that's about to be stored (Copilot).
  def self.awaiting?(candidate)
    source = candidate.source
    source.source_kind == "web_page" && !source.crawl_needs_human? && candidate.created_at > WAIT.ago &&
      fetch_pending?(source, candidate) &&
      (source.content_text.blank? || !DataQuality::Plugins::WebPage.new.quote_in_source?(source, candidate.quote))
  end

  # The job will fetch it for this claim: not fetched since the claim was
  # made, and not already today (Snapshot fetches a source once a day, so a
  # page fetched or blocked earlier today is checked as it stands; Copilot).
  def self.fetch_pending?(source, candidate)
    source.fetched_at.nil? || (source.fetched_at < candidate.created_at && source.fetched_at.to_date != Date.current)
  end

  # Fetches each source, one at a time, through the polite Fetcher. A failure
  # on one page is reported and the rest are still fetched.
  def self.store(source_ids, fetcher: DataQuality::Fetcher.new)
    Source.where(id: source_ids).order(:id).to_h do |source|
      result = begin
        # Checked again under the row lock as the job runs: a delayed job
        # never fetches a page that became a person's to look at meanwhile
        # (three blocks in a row, or robots.txt), so it stays that way (Copilot).
        # A page a crawler took over meanwhile (e.g. DOE's loan page) is its
        # crawler's to store, in its own form (Copilot).
        DataQuality::Snapshot.claim(source) do
          if source.source_kind != "web_page" then :not_web_page
          elsif source.crawl_needs_human? then :needs_human
          else DataQuality::Snapshot.take(source, fetcher:)
          end
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { source_id: source.id })
        :error
      end
      [ source.id, result ]
    end
  end
end
