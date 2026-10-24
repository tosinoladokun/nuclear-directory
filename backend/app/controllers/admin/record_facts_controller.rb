# Add a fact (#202): a role or a technology on a company, by hand, from a
# public source and its quote. The form previews with a GET (a dry run of
# DataQuality::Review.add_company_fact, so the preview checks what adding
# would); Add fact writes it pending, and it's published as any fact is.
class Admin::RecordFactsController < Admin::BaseController
  KINDS = DataQuality::Review::COMPANY_FACTS.keys.freeze

  before_action :load_company

  def new
    @kind = params[:kind].presence_in(KINDS) || KINDS.first
    @added = add(dry_run: true) if params[:preview]
  end

  def create
    @kind = params[:kind].presence_in(KINDS) || KINDS.first
    @added = add(dry_run: false)
    return render(:new, status: :unprocessable_content) unless @added.ok?

    flash[:notice] = "Added. It isn't published yet."
    redirect_after admin_record_path(type: "Organization", id: @company.id, back: params[:back].presence)
  end

  private
    # Companies only for now; a plant's facts are its links and units (next).
    def load_company
      raise ActiveRecord::RecordNotFound unless params[:type] == "Organization"

      # Not on a removed, rejected or merged-away company (the page shows no
      # Add fact there either): an open form or direct request is refused too.
      @company = Organization.where(verification_status: %w[verified pending]).find(params[:id])
    end

    def add(dry_run:)
      DataQuality::Review.add_company_fact(organization_id: @company.id, kind: @kind, key: params[:key], url: params[:url], quote: params[:quote],
        by: actor, dry_run:)
    end
end
