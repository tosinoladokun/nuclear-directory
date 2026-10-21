# Add a fact (#202): by hand, from a public source and its quote, on a
# company (what it does, a technology, a link to another company) or on a
# plant site (a company link, a unit). The form previews with a GET (a dry
# run of the Review method, so the preview checks what adding would); Add
# fact writes it pending, and it's published as any fact is.
class Admin::RecordFactsController < Admin::BaseController
  KINDS = {
    "Organization" => { "role" => "What it does", "technology" => "Technology", "company_link" => "Link to a company" },
    "Facility" => { "plant_link" => "Company link", "unit" => "Unit" }
  }.freeze
  LINKS = %w[company_link plant_link].freeze

  before_action :load_record

  def new
    @kind = params[:kind].presence_in(KINDS.fetch(@type).keys) || KINDS.fetch(@type).keys.first
    @other = Organization.where(verification_status: %w[verified pending]).find_by(id: params[:other]) if LINKS.include?(@kind)
    @choices = company_choices if LINKS.include?(@kind) && !@other
    @added, @plan = add(dry_run: true) if params[:preview]
  end

  def create
    @kind = params[:kind].presence_in(KINDS.fetch(@type).keys) || KINDS.fetch(@type).keys.first
    @other = Organization.find_by(id: params[:other]) if LINKS.include?(@kind)
    @added, @plan = add(dry_run: false)
    return render(:new, status: :unprocessable_content) unless @added.ok?

    flash[:notice] = "Added. It isn't public yet."
    redirect_after admin_record_path(type: @type, id: @record.id, back: params[:back].presence, anchor: "item-#{@added.ref.type}-#{@added.ref.id}")
  end

  private
    # A live or waiting company, or plant site: not a removed, rejected or
    # merged-away one (the page shows no Add fact there either), and not a
    # unit (its facts are its site's).
    def load_record
      @type = params[:type].presence_in(KINDS.keys) or raise ActiveRecord::RecordNotFound

      scope = @type.constantize.where(verification_status: %w[verified pending])
      scope = scope.where(parent_id: nil) if @type == "Facility"
      @record = scope.find(params[:id])
    end

    def add(dry_run:)
      common = { url: params[:url], quote: params[:quote], by: actor, dry_run: }
      case @kind
      when "unit" then [ DataQuality::Review.add_unit(site_id: @record.id, name: params[:name], docket: params[:docket], **common), nil ]
      when *LINKS
        DataQuality::Review.add_link(kind: @kind, record_id: @record.id, other_id: @other&.id, verb: params[:verb], share: params[:share],
          started_on: params[:started_on], ended_on: params[:ended_on], swap: params[:swap] == "1", **common)
      else
        [ DataQuality::Review.add_company_fact(organization_id: @record.id, kind: @kind, key: params[:key], **common), nil ]
      end
    end

    # Live and waiting companies whose name or another name has the search in it.
    def company_choices
      query = params[:q].to_s.strip
      return [] if query.length < 2

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      scope = Organization.where(verification_status: %w[verified pending])
      scope = scope.where.not(id: @record.id) if @type == "Organization"
      scope.where("organizations.name ILIKE ?", pattern)
        .or(scope.where(id: OrganizationAlias.where("alias ILIKE ?", pattern).select(:organization_id))).order(:name).limit(20).to_a
    end
end
