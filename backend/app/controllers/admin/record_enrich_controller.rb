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
  end

  def create
    if @company.website.blank?
      flash[:alert] = "It has no website to read yet. Add one with Edit first."
    elsif !@company.website.to_s.strip.match?(%r{\Ahttps://[^\s/]+}i)
      flash[:alert] = "Its website needs to start with https:// before its pages can be read. Fix it with Edit first."
    else
      @company.update_columns(enrich_requested_at: Time.current)
      DataQuality::RunJob.perform_later(SOURCE_KIND)
      flash[:notice] = "Reading its pages. What they state comes back here to decide, usually within a few minutes."
    end
    redirect_after admin_record_enrich_path(type: "Organization", id: @company.id)
  end

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
    results = ActiveRecord::Base.transaction do
      # Approval's lock order: sources, then claims, then the company.
      Source.lock.where(id: Candidate.where(id: ids).select(:source_id)).order(:id).ids
      Candidate.lock.where(id: ids).order(:id).ids
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

        field = claim.kind == "organization" && [ claim.subject_id, claim.payload.to_h.except("name").keys.sort ]
        next "another finding for the same field was approved just now; decide this one on its own" if field && fields.include?(field)

        fields << field if field
        nil
      end
      DataQuality::Review.approve(ids, by: actor, reason: "Approved in Enrich: Joy agrees", only_recommended: true, safe_check: check)
    end
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Approved #{helpers.pluralize(done.size, 'finding')}." if done.any?
    flash[:alert] = stopped.map { |r| "##{r.candidate_id}: #{Array(r.errors).to_sentence}" }.join("; ") if stopped.any?
    redirect_after admin_record_enrich_path(type: "Organization", id: @company.id)
  end

  private
    def load_company
      raise ActiveRecord::RecordNotFound unless params[:type] == "Organization"

      @company = Organization.where(verification_status: %w[verified pending]).find(params[:id])
    end

    # What its own pages stated, still waiting: the claims on its pages since it was asked.
    def finding_ids
      @finding_ids ||= begin
        domain = @company.domain.presence
        pages = domain ? Source.where(source_kind: SOURCE_KIND, domain: [ domain, "www.#{domain}" ]) : Source.none
        # Only what this request found (since it was asked); older findings stay in Checks.
        # A trade-press lead (#127) waits for Data Quality, never here.
        scope = Candidate.where(source: pages, status: %w[new matched needs_review]).where("candidates.payload->>'lead' IS DISTINCT FROM 'true'")
        scope = scope.where(created_at: @company.enrich_requested_at..) if @company.enrich_requested_at
        scope.order(:id).ids
      end
    end
end
