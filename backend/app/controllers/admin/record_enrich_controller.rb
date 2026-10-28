# Enrich (#479): the admin asks for one company's own pages to be read
# against the fixed field list (DataQuality::Plugins::CompanyPages), then
# decides what they found here, where they clicked (Tosin, 21 Oct): Approve
# or Reject each, or "Approve all Joy agrees with" for this company's
# findings. Same approval path and checks as Checks; the same items show in
# Today and Checks too.
class Admin::RecordEnrichController < Admin::BaseController
  SOURCE_KIND = "company_pages".freeze

  before_action :load_company

  def show
    @items = DataQuality::Review.items(finding_ids)
    # The shortcut takes what Joy recommends and nothing holds back from a
    # bulk approval (a change to a record a person decided is approved one
    # at a time, as on Checks).
    @agreed = @items.select { |item| item.ai_recommendation == "recommend_publish" && item.status != "needs_review" && item.held.nil? }.map(&:candidate_id)
    @runs = CrawlRun.where(source_kind: SOURCE_KIND).order(started_at: :desc).limit(4)
    # Reading what its pages say, after they were fetched: still going, or
    # stopped. The first extraction after its read (runs go one at a time),
    # so a later company's read never stands in for this one's.
    @extract = CrawlRun.where(source_kind: SOURCE_KIND, stage: "extract").where(started_at: @company.enriched_at..).order(:started_at).first if @company.enriched_at
    # Its home page, when the last read couldn't use it (blocked, an error): said, with Read again.
    @home = Source.find_by(url: @company.website.to_s.strip) if @company.website.present?
    # Its SEC record (part 3), read too when it has a CIK: its own status.
    @sec = Source.find_by(url: format(DataQuality::Plugins::CompanyPages::EDGAR, @company.sec_cik.to_i)) if @company.sec_cik.present?
  end

  def create
    if (refusal = self.class.request!(@company))
      flash[:alert] = refusal
    else
      flash[:notice] = "Reading its pages. What they state comes back here to decide, usually within a few minutes."
    end
    redirect_after admin_record_enrich_path(type: "Organization", id: @company.id)
  end

  # Asks for a company's pages to be read (also from Leads, #484): nil once
  # queued, or why it can't be. A retry after a read whose extraction failed
  # resumes that request, so findings already made from its pages stay.
  def self.request!(company)
    return "It has no website or SEC number to read yet. Add one with Edit first." if company.website.blank? && company.sec_cik.blank?
    if company.website.present? && !usable_website?(company.website)
      return "Its website needs to be a full https:// address before its pages can be read. Fix it with Edit first."
    end

    failed = company.enriched_at && CrawlRun.where(source_kind: SOURCE_KIND, stage: "extract").where(started_at: company.enriched_at..)
      .order(:started_at).first&.failed?
    company.update_columns(failed ? { enriched_at: nil } : { enrich_requested_at: Time.current })
    DataQuality::RunJob.perform_later(SOURCE_KIND)
    nil
  end

  # The address's form only: its page may be a saved source already.
  def self.usable_website?(url) = Organization.readable_website?(url)

  def decide
    id = params[:candidate_id].to_i
    raise ActiveRecord::RecordNotFound unless finding_ids.include?(id)

    result = if params[:decision] == "approve"
      DataQuality::Review.approve([ id ], by: actor, reason: "Approved in Enrich").first
    else
      DataQuality::Review.reject([ id ], by: actor, reason: "Rejected in Enrich").first
    end
    if result&.ok? then flash[:notice] = params[:decision] == "approve" ? "Approved." : "Rejected."
    else flash[:alert] = "Not done: #{Array(result&.errors).to_sentence.presence || 'it was decided already'}."
    end
    redirect_after admin_record_enrich_path(type: "Organization", id: @company.id)
  end

  # Exactly the findings the page offered (their fingerprint), each checked
  # again as it's approved; only those Joy recommends.
  def agreed
    ids = Array(params[:ids]).map(&:to_i).sort
    if params[:shown] != Admin::CandidatesController.fingerprint(ids) || !(ids - finding_ids).empty?
      flash[:alert] = "The list changed since you opened it, so nothing was approved. Check it and try again."
      return redirect_after(admin_record_enrich_path(type: "Organization", id: @company.id))
    end

    # One batch under the company's lock: whether a person had decided each
    # record is read before any of these writes (the first approval mustn't
    # hold back the rest), and two findings for one field never both land.
    directory = DataQuality::DirectoryClient.new
    results = begin
      ActiveRecord::Base.transaction do
        # Review.approve's order: each claim's source then the claim, in claim
        # order; then the company.
        Candidate.where(id: ids).order(:id).pluck(:id, :source_id).each do |id, source_id|
          Source.lock.find(source_id)
          Candidate.lock.find(id)
        end
        Organization.lock.find(@company.id)
        # Only the company row, locked here, is read before the batch; any
        # other record (a role, a technology) is checked live under its own lock.
        own = Candidate.where(id: ids, subject_type: "Organization", subject_id: @company.id).ids
        company_decided = @company.reload.verified_by.to_s.start_with?("human:")
        decided = own.index_with { company_decided }
        fields = []
        check = lambda do |claim|
          held = DataQuality::Review.held_reason(claim, directory:, decided: decided[claim.id])
          next held if held

          mine = claim.kind == "organization" ? claim.payload.to_h.except("name").keys.map { |key| [ claim.subject_id, key ] } : []
          next "another finding for the same field was approved just now; decide this one on its own" if mine.intersect?(fields)

          nil
        end
        # One at a time, so a field counts as taken only once its finding is in.
        ids.flat_map do |id|
          pending = []
          held = lambda do |claim|
            why = check.call(claim)
            pending.concat(claim.kind == "organization" ? claim.payload.to_h.except("name").keys.map { |key| [ claim.subject_id, key ] } : []) unless why
            why
          end
          DataQuality::Review.approve([ id ], by: actor, reason: "Approved in Enrich: Joy agrees", only_recommended: true, safe_check: held).tap do |result|
            fields.concat(pending) if result.sole.ok?
          end
        end
      end
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      # Rolled back whole: each stays waiting, saying why.
      ids.map { |id| DataQuality::Review::Result.new(candidate_id: id, ref: nil, errors: [ DataQuality::Review::BUSY ]) }
    end
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Approved #{helpers.pluralize(done.size, 'finding')}." if done.any?
    flash[:alert] = stopped.map { |r| "##{r.candidate_id}: #{Array(r.errors).to_sentence}" }.join("; ") if stopped.any?
    redirect_after admin_record_enrich_path(type: "Organization", id: @company.id)
  end

  private
    # A whole https address a page can be saved under (no spaces, a host).
    def load_company
      raise ActiveRecord::RecordNotFound unless params[:type] == "Organization"

      @company = Organization.where(verification_status: %w[verified pending]).find(params[:id])
    end

    # What its own pages stated, still waiting: the claims on its pages since it was asked.
    def finding_ids
      @finding_ids ||= begin
        domain = @company.domain.presence
        pages = domain ? Source.where(source_kind: SOURCE_KIND, domain: [ domain, "www.#{domain}" ]) : Source.none
        # Its SEC record too (part 3), when it has a CIK.
        pages = pages.or(Source.where(source_kind: SOURCE_KIND, url: format(DataQuality::Plugins::CompanyPages::EDGAR, @company.sec_cik.to_i))) if @company.sec_cik.present?
        # Only what this request found (since it was asked); older findings stay in Checks.
        # A trade-press lead (#127) waits for Data Quality, never here.
        # A "no longer listed" flag (review_origin dropped) is decided in Checks, with its reason.
        scope = Candidate.where(source: pages, status: %w[new matched needs_review]).where("candidates.payload->>'lead' IS DISTINCT FROM 'true'")
          .where("candidates.review_origin IS DISTINCT FROM 'dropped'")
        scope = scope.where(created_at: @company.enrich_requested_at..) if @company.enrich_requested_at
        scope.order(:id).ids
      end
    end
end
