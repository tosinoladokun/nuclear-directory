# "Same as…" (#391): a waiting claim whose company is still a question (no
# exact match, only similar names) is settled here in one click: the same as
# a company already listed, a subsidiary of one, or a new company. The claim
# then goes through match and verify again (queued), and waits for Approve
# like any other; nothing is approved here.
class Admin::CandidateSettlesController < Admin::BaseController
  before_action :load_claim

  def show
    @query = params[:q].to_s.strip
    @choices = company_choices
  end

  def create
    result = DataQuality::Review.settle_company(@candidate.id, end_key: @end_key, choice: params[:choice], record_id: params[:record_id].presence&.to_i, by: actor)
    if result.ok?
      flash[:notice] = "Settled. It goes through the checks again and comes back to you to approve."
      redirect_after(params[:back].presence&.then { |back| back.start_with?("/admin") ? back : nil } || admin_checks_path)
    else
      flash[:alert] = "Not settled: #{result.errors.to_sentence}."
      redirect_after admin_candidate_settle_path(@candidate.id, end: @end_key, back: params[:back].presence)
    end
  end

  private
    def load_claim
      @candidate = Candidate.find(params[:id])
      @ends = DataQuality::Review.open_company_ends(@candidate)
      @end_key, @name = @ends.find { |key, _| key.to_s == params[:end].to_s } || @ends.first
      return if @name

      flash[:alert] = "Its company isn't a question any more."
      redirect_after admin_checks_path
    end

    # Live and waiting companies by name or another name; with no search, the
    # similar ones match named (its note) and the name itself.
    def company_choices
      scope = Organization.where(verification_status: %w[verified pending])
      if @query.length >= 2
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
        return scope.where("organizations.name ILIKE ?", pattern)
          .or(scope.where(id: OrganizationAlias.where("alias ILIKE ?", pattern).select(:organization_id))).order(:name).limit(20).to_a
      end

      similar = @candidate.notes.to_s[/but similar: (.*?)\. Same record/, 1].to_s.split("; ")
      scope.where(name: [ *similar, @name ]).order(:name).to_a
    end
end
